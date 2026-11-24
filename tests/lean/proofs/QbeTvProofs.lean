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
import PionProofs.QbeTvTgt
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

/-! ## Running the skipped instructions -/

/-- `loop` from a relation between a state and the loop's result. -/
theorem loop_ok_rel {α β : Type} (body : α → Result (ControlFlow α β)) (P : α → β → Prop)
    (hb : ∀ x c r, body x = ok c → (match c with | .cont x' => P x' r | .done y => r = y) → P x r) :
    ∀ x r, loop body x = ok r → P x r := by
  apply loop.fixpoint_induct body (motive := fun f => ∀ x r, f x = ok r → P x r)
  · exact adm1 P
  · intro f ih x r h
    obtain ⟨c, hc, h⟩ := bind_eq_ok h
    apply hb x c r hc
    cases c with
    | cont x' => exact ih x' r h
    | done y => exact (ok_inj' h).symm

/-- The source runs instructions `x … x1-1` of its block, none touching the world. -/
theorem src_skip_run {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv} {b : Nat} {B : Block}
    {s0 : MState W} {n : Nat} {res : TermOutcome W} :
    ∀ (d x : Nat) (s : MState W), SIn G src si svid facts savail o args env b B s0 s x →
      restFrom o args src n b B x s = some res → x + d ≤ B.insts.val.length →
      (∀ i (hi : i < B.insts.val.length), x ≤ i → i < x + d → NoWorld B.insts.val[i]) →
      ∃ s', SIn G src si svid facts savail o args env b B s0 s' (x + d) ∧
        restFrom o args src n b B (x + d) s' = some res ∧ s'.world = s.world
  | 0, x, s, hin, hrun, _, _ => ⟨s, hin, hrun, rfl⟩
  | d + 1, x, s, hin, hrun, hle, hnw => by
    have hx : x < B.insts.val.length := by omega
    rw [restFrom_step o args src hx] at hrun
    cases hex : execInst o args s B.insts.val[x] with
    | none => rw [hex] at hrun; simp at hrun
    | some s1 =>
      rw [hex] at hrun
      simp only [Option.bind_some] at hrun
      have hin1 := src_inst_step C hin hx hex
      obtain ⟨s', h1, h2, h3⟩ := src_skip_run C d (x + 1) s1 hin1 hrun (by omega)
        (fun i hi h1 h2 => hnw i hi (by omega) (by omega))
      refine ⟨s', by rw [show x + (d + 1) = x + 1 + d by omega]; exact h1,
        by rw [show x + (d + 1) = x + 1 + d by omega]; exact h2, ?_⟩
      rw [h3, execInst_world (hnw x hx (le_refl _) (by omega)) hex]

/-- The target runs one instruction the replay skips. -/
theorem tgt_pure_exec {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {env : SymEnv} {tb : Nat}
    {Bt : Block} {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {ts : MState W} {tx : Nat}
    {schain : List Std.I32}
    (hin : TIn G tgt ti tvid tavail env tb Bt ts tx schain) (hx : tx < Bt.insts.val.length)
    (hpt : PureTgt G tvid Bt.insts.val[tx]) (henv : EnvOK o args env) :
    ∃ ts', execInst o args ts Bt.insts.val[tx] = some ts' ∧ ts'.world = ts.world ∧
      TIn G tgt ti tvid tavail env tb Bt ts' (tx + 1) schain := by
  obtain ⟨-, hinsts, -, -⟩ := C.block tb Bt hin.reach hin.blk
  have hops := opsAgree_of_avail hin.regs henv.1 (hinsts tx hx).1
  obtain ⟨hnw, hcase⟩ := hpt
  -- the run of the instruction, and the value of its destination
  have key : ∃ ts', execInst o args ts Bt.insts.val[tx] = some ts' ∧
      ∀ v, 0 ≤ (instDst Bt.insts.val[tx]).val → tvid[(instDst Bt.insts.val[tx]).val.toNat]? = some v →
        Valid G v → ts'.regs (instDst Bt.insts.val[tx]).val.toNat = evI G env v ∧
          PureDef G tvid Bt.insts.val[tx] v := by
    have hpd_of : ∀ ts', execInst o args ts Bt.insts.val[tx] = some ts' →
        (∀ v, 0 ≤ (instDst Bt.insts.val[tx]).val → tvid[(instDst Bt.insts.val[tx]).val.toNat]? = some v →
          Valid G v → PureDef G tvid Bt.insts.val[tx] v) →
        ∀ v, 0 ≤ (instDst Bt.insts.val[tx]).val → tvid[(instDst Bt.insts.val[tx]).val.toNat]? = some v →
          Valid G v → ts'.regs (instDst Bt.insts.val[tx]).val.toNat = evI G env v ∧
            PureDef G tvid Bt.insts.val[tx] v := by
      intro ts' hex hpd v hd0 hv hvv
      have hp := hpd v hd0 hv hvv
      rw [pureDef_exec hp o args env ts henv hops] at hex
      cases hex
      exact ⟨by simp [setReg], hp⟩
    rcases hcase with hck | ⟨d, c, op, a, bb, he, htr, hsafe, hval⟩
    · have hpd : ∀ v, 0 ≤ (instDst Bt.insts.val[tx]).val → tvid[(instDst Bt.insts.val[tx]).val.toNat]? = some v →
          Valid G v → PureDef G tvid Bt.insts.val[tx] v :=
        fun v hd0 hv hvv => (C.defs tb Bt hin.blk tx hx v hd0 hv hvv.1 hck).2
      have hex : ∃ ts', execInst o args ts Bt.insts.val[tx] = some ts' := by
        generalize Bt.insts.val[tx] = inst at hck
        cases inst with
        | Par _ _ _ => exact ⟨_, rfl⟩
        | Un _ _ _ _ => exact ⟨_, rfl⟩
        | Bin d c op a b =>
          simp only [TgtChecked] at hck
          obtain ⟨v, hv⟩ := Option.ne_none_iff_exists'.1 (evalBin_some_of_not_trap hck c
            (atomVal o ts.regs (binArgCls op c 0) a) (atomVal o ts.regs (binArgCls op c 1) b))
          exact ⟨{ ts with regs := setReg ts.regs d v }, by simp only [execInst, hv, Option.map_some]⟩
        | _ => exact absurd hck (by simp [TgtChecked])
      obtain ⟨ts', hts'⟩ := hex
      exact ⟨ts', hts', hpd_of ts' hts' hpd⟩
    · have hops' := hops
      rw [he] at hops'
      obtain ⟨v, hv⟩ := Option.ne_none_iff_exists'.1 (hsafe o env ts.regs hops'.1 hops'.2)
      have hex : execInst o args ts Bt.insts.val[tx] = some { ts with regs := setReg ts.regs d v } := by
        rw [he]; simp only [execInst, hv, Option.map_some]
      refine ⟨_, hex, hpd_of _ hex (fun v' hd0 hv' hvv => ?_)⟩
      have hd0' : 0 ≤ d.val := by rw [he] at hd0; exact hd0
      have hv'' : tvid[d.val.toNat]? = some v' := by rw [he] at hv'; exact hv'
      exact (hval v' hd0' hv'' hvv.1).2
  obtain ⟨ts', hex, hval⟩ := key
  refine ⟨ts', hex, execInst_world hnw hex, tgt_step C hin hx hex (fun v hd0 hv hvv => ?_)⟩
  obtain ⟨h1, h2⟩ := hval v hd0 hv hvv
  exact ⟨h1, Or.inl h2⟩

/-- The target runs instructions `x … x1-1` of its block, all skippable by the replay. -/
theorem tgt_skip_run {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {env : SymEnv} {tb : Nat}
    {Bt : Block} {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {schain : List Std.I32}
    (henv : EnvOK o args env) {res : TermOutcome W} :
    ∀ (d x : Nat) (ts : MState W), TIn G tgt ti tvid tavail env tb Bt ts x schain → x + d ≤ Bt.insts.val.length →
      (∀ i (hi : i < Bt.insts.val.length), x ≤ i → i < x + d → PureTgt G tvid Bt.insts.val[i]) →
      ∃ ts', TIn G tgt ti tvid tavail env tb Bt ts' (x + d) schain ∧ ts'.world = ts.world ∧
        ((∃ m, restFrom o args tgt m tb Bt (x + d) ts' = some res) →
          ∃ m, restFrom o args tgt m tb Bt x ts = some res)
  | 0, x, ts, hin, _, _ => ⟨ts, hin, rfl, id⟩
  | d + 1, x, ts, hin, hle, hpt => by
    have hx : x < Bt.insts.val.length := by omega
    obtain ⟨ts1, hex, hw1, hin1⟩ := tgt_pure_exec C hin hx (hpt x hx (le_refl _) (by omega)) henv
    obtain ⟨ts', h1, h2, h3⟩ := tgt_skip_run C henv d (x + 1) ts1 hin1 (by omega)
      (fun i hi h1 h2 => hpt i hi (by omega) (by omega))
    refine ⟨ts', by rw [show x + (d + 1) = x + 1 + d by omega]; exact h1, by rw [h2, hw1], fun hg => ?_⟩
    obtain ⟨m, hm⟩ := h3 (by rw [show x + 1 + d = x + (d + 1) by omega]; exact hg)
    exact ⟨m, by rw [restFrom_step o args tgt hx, hex, Option.bind_some]; exact hm⟩

/-! ## The source between blocks -/

/-- The source is about to enter block `b` from block `prev`, `n` blocks of run left. -/
def SrcAbout (G : ValGraph) (src : Func) (si : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (savail : Pion.Array Bool) {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (env : SymEnv)
    (prev : Nat) (b : Std.I32) (n : Nat) (s : MState W) (res : TermOutcome W) : Prop :=
  SEnd G src si svid facts savail env prev s.regs ∧ SHist G src si svid facts savail o env prev ∧
    (∃ Bp, src.blocks.val[prev]? = some Bp ∧ EdgeTaken o s.regs Bp.term b) ∧ 0 ≤ b.val ∧
    evalFrom o args src n prev b.val.toNat s = some res ∧
    env.symAddr = o.symAddr ∧ ∀ c k, env.paramVal c k = argVal args k

theorem termCont_edge {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {f : Func} {n b : Nat}
    {t : Term} {s : MState W} {res : TermOutcome W} {sj : Std.I32}
    (h : termCont o args f n b t s = some res) (he : EdgeTaken o s.regs t sj) :
    0 ≤ sj.val ∧ evalFrom o args f n b sj.val.toNat s = some res := by
  unfold termCont at h
  cases t with
  | Jmp d =>
    simp only [EdgeTaken] at he
    subst he
    simp only at h
    unfold blockId at h
    split at h
    · rename_i h0; exact ⟨h0, by simpa using h⟩
    · simp at h
  | Jnz a d1 d2 =>
    simp only [EdgeTaken] at he
    simp only at h
    rw [← he] at h
    unfold blockId at h
    split at h
    · rename_i h0; exact ⟨h0, by simpa using h⟩
    · simp at h
  | _ => exact absurd he (by simp [EdgeTaken])

/-- The source at the end of a block leaves it along the edge its terminator takes. -/
theorem src_leave {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv}
    {b : Nat} {B : Block} {s0 s : MState W} {n : Nat} {res : TermOutcome W} {sj : Std.I32}
    (hin : SIn G src si svid facts savail o args env b B s0 s B.insts.val.length)
    (hhist : SHist G src si svid facts savail o env b)
    (hrun : restFrom o args src n b B B.insts.val.length s = some res) (he : EdgeTaken o s.regs B.term sj) :
    SrcAbout G src si svid facts savail o args env b sj n s res := by
  rw [restFrom_end] at hrun
  obtain ⟨h0, hev⟩ := termCont_edge hrun he
  exact ⟨sIn_end hin, hhist, ⟨B, hin.blk, he⟩, h0, hev, hin.sym, hin.par⟩

/-- The source enters the block it is about to enter. -/
theorem src_enter_about {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv}
    {prev : Nat} {b : Std.I32} {n : Nat} {s : MState W} {res : TermOutcome W}
    (ha : SrcAbout G src si svid facts savail o args env prev b n s res) :
    ∃ n' Bb R, n = n' + 1 ∧ src.blocks.val[b.val.toNat]? = some Bb ∧
      execPhis o s.regs prev Bb.phis.val s.regs = some R ∧
      SIn G src si svid facts savail o args
        (enterEnv o args env b Bb prev s.regs { regs := R, world := s.world }) b.val.toNat Bb
        { regs := R, world := s.world } { regs := R, world := s.world } 0 ∧
      SHist G src si svid facts savail o
        (enterEnv o args env b Bb prev s.regs { regs := R, world := s.world }) b.val.toNat ∧
      restFrom o args src n' b.val.toNat Bb 0 { regs := R, world := s.world } = some res := by
  obtain ⟨hend, hhist, ⟨Bp, hBp, hedge⟩, hb0, hev, hsym, hpar⟩ := ha
  cases n with
  | zero => simp [evalFrom] at hev
  | succ n' =>
    rw [evalFrom_succ] at hev
    cases hBb : src.blocks.val[b.val.toNat]? with
    | none => rw [hBb] at hev; simp at hev
    | some Bb =>
      rw [hBb] at hev
      simp only at hev
      cases hR : execPhis o s.regs prev Bb.phis.val s.regs with
      | none => rw [hR] at hev; simp at hev
      | some R =>
        rw [hR] at hev
        simp only [Option.bind_some] at hev
        have hbi : i32n b.val.toNat = b := (i32n_of_val hb0).symm
        have := src_enter C (args := args) s.world hend hhist hsym hpar hBp hBb (by rw [hbi]; exact hedge) hR
        rw [hbi] at this
        exact ⟨n', Bb, R, rfl, rfl, hR, this.1, this.2, hev⟩

/-- Through trivial blocks the source keeps its environment and its world. -/
theorem triv_run {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv} {res : TermOutcome W}
    {b0 : Std.I32} {b : Std.I32} (hr : TrivReach src b0 b) :
    ∀ (prev : Nat) (n : Nat) (s : MState W), SrcAbout G src si svid facts savail o args env prev b0 n s res →
      ∃ prev' n' s', SrcAbout G src si svid facts savail o args env prev' b n' s' res ∧ n' ≤ n ∧
        s'.world = s.world := by
  induction hr with
  | refl => exact fun prev n s ha => ⟨prev, n, s, ha, le_refl _, rfl⟩
  | @step b nn B hreach hb0 hB htriv ih =>
    intro prev n s ha
    obtain ⟨prev', n', s', ha', hn', hw'⟩ := ih prev n s ha
    obtain ⟨m, Bb, R, rfl, hBb, hR, hin, hhist, hrun⟩ := src_enter_about C ha'
    rw [hB] at hBb; cases hBb
    obtain ⟨hph, hins, hterm⟩ := htriv
    have henv : enterEnv o args env b B prev' s'.regs { regs := R, world := s'.world } = env :=
      enterEnv_trivial o args env b B prev' s'.regs _ hph (fun inst hm => (hins inst hm).2)
    rw [henv] at hin hhist
    obtain ⟨s'', hin2, hrun2, hw2⟩ := src_skip_run C B.insts.val.length 0 _ hin hrun (by omega)
      (fun i hi _ _ => (hins _ (List.getElem_mem _)).1)
    simp only [Nat.zero_add] at hin2 hrun2
    have hedge : EdgeTaken o s''.regs B.term nn := by rw [hterm]; rfl
    refine ⟨b.val.toNat, m, s'', src_leave hin2 hhist hrun2 hedge, by omega, ?_⟩
    rw [hw2, hw']

/-! ## Moves inside a certified pair -/

theorem tin_reenv {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {env env' : SymEnv} {tb : Nat} {Bt : Block} {W : Type} {ts : MState W} {tx : Nat}
    {schain schain' : List Std.I32} (hin : TIn G tgt ti tvid tavail env tb Bt ts tx schain)
    (hst : ∀ t, CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt tx t → ∀ v, tvid[t]? = some v → Valid G v →
      evI G env' v = evI G env v)
    (hsub : ∀ x ∈ schain, x ∈ schain') : TIn G tgt ti tvid tavail env' tb Bt ts tx schain' := by
  refine ⟨hin.reach, hin.blk, hin.le, fun t ht v hv hvv => ?_, fun k hk hkl v hd0 hv hvv => ?_⟩
  · rw [hin.regs t ht v hv hvv, hst t ht v hv hvv]
  · rcases hin.stab k hk hkl v hd0 hv hvv with h | ⟨c, sb, i, hsb, hn⟩
    · exact Or.inl h
    · exact Or.inr ⟨c, sb, i, hsub sb hsb, hn⟩

/-- Inside a pair the source enters block `sj`, outside the pair's source blocks; the target keeps
agreeing (the checks `bm_has` and `src_enter_scope_ok`). -/
theorem pair_src_move {G : ValGraph} {src tgt : Func} {si ti : FnInfo} {svid tvid : List Std.I32}
    {facts : List Fact} {savail tavail : Pion.Array Bool} {bm_t bm_s : List Std.I32}
    (CS : SrcCtx G src si svid facts savail) (CT : TgtCtx G tgt ti tvid tavail bm_t bm_s)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv} {prev : Nat} {sj : Std.I32}
    {n : Nat} {s : MState W} {res : TermOutcome W}
    (hab : SrcAbout G src si svid facts savail o args env prev sj n s res)
    {tc : Nat} {Bt : Block} {ts : MState W} {tx : Nat} {schain : List Std.I32}
    (htin : TIn G tgt ti tvid tavail env tc Bt ts tx schain) (hsj : sj ∉ schain)
    (hbm : ∃ j : Nat, bm_t[j]? = some (i32n tc) ∧ bm_s[j]? = some sj)
    (hscope : ∀ P ∈ Bt.phis.val, ∀ v, tvid[P.dst.val.toNat]? = some v → Valid G v → StableAt G sj v) :
    ∃ n' Bj R env', n = n' + 1 ∧ src.blocks.val[sj.val.toNat]? = some Bj ∧
      SIn G src si svid facts savail o args env' sj.val.toNat Bj { regs := R, world := s.world }
        { regs := R, world := s.world } 0 ∧
      SHist G src si svid facts savail o env' sj.val.toNat ∧
      restFrom o args src n' sj.val.toNat Bj 0 { regs := R, world := s.world } = some res ∧
      TIn G tgt ti tvid tavail env' tc Bt ts tx (sj :: schain) ∧ AgreeExcept sj env env' := by
  obtain ⟨n', Bj, R, hn, hBj, hR, hin, hhist, hrun⟩ := src_enter_about CS hab
  have hag := enterEnv_agree o args env sj Bj prev s.regs { regs := R, world := s.world }
  refine ⟨n', Bj, R, _, hn, hBj, hin, hhist, hrun, tin_reenv htin (fun t ht v hv hvv => ?_)
    (fun x hx => List.mem_cons_of_mem _ hx), hag⟩
  obtain ⟨j, hj1, hj2⟩ := hbm
  have hst := tgt_stable CT htin hsj (fun x hx hav v hv hvv =>
    CT.scope tc htin.reach (by
      have := htin.blk; by_contra hc; rw [List.getElem?_eq_none (by omega)] at this; cases this)
      j sj hj1 hj2 x hx hav v hv hvv.1) hscope t ht v hv hvv
  exact hst env _ hag

/-- The target at the end of block `tc` leaving to `tj`: running `tj` from its start is running
`tc` from its end. -/
theorem tgt_back_edge {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {tgt : Func} {tc : Nat}
    {Bt : Block} {ts : MState W} {tj : Std.I32} (htj0 : 0 ≤ tj.val) (hedge : EdgeTaken o ts.regs Bt.term tj)
    {Bj : Block} (hBj : tgt.blocks.val[tj.val.toNat]? = some Bj) {R : Nat → BitVec 64}
    (hR : execPhis o ts.regs tc Bj.phis.val ts.regs = some R) {m : Nat} {res : TermOutcome W}
    (h : restFrom o args tgt m tj.val.toNat Bj 0 { ts with regs := R } = some res) :
    restFrom o args tgt (m + 1) tc Bt Bt.insts.val.length ts = some res := by
  rw [restFrom_end]
  have hev : evalFrom o args tgt (m + 1) tc tj.val.toNat ts = some res := by
    rw [evalFrom_succ, hBj]
    simp only [hR, Option.bind_some]
    exact h
  unfold termCont
  cases hT : Bt.term with
  | Jmp d =>
    rw [hT] at hedge; simp only [EdgeTaken] at hedge; subst hedge
    simp only [blockId, htj0, ↓reduceIte, Option.bind_some]; exact hev
  | Jnz a d1 d2 =>
    rw [hT] at hedge; simp only [EdgeTaken] at hedge
    simp only
    rw [← hedge]
    simp only [blockId, htj0, ↓reduceIte, Option.bind_some]; exact hev
  | _ => rw [hT] at hedge; exact absurd hedge (by simp [EdgeTaken])

/-- Both runs enter the blocks of the next certified pair (`next_ok`: `edge_ok`, with the next
pair's `head_ok` and `bm_has`). -/
theorem pair_enter {G : ValGraph} {src tgt : Func} {si ti : FnInfo} {svid tvid : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {savail tavail : Pion.Array Bool} {bm_t bm_s : List Std.I32}
    (CS : SrcCtx G src si svid.val facts.val savail) (CT : TgtCtx G tgt ti tvid.val tavail bm_t bm_s)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv} {sc : Nat} {sj : Std.I32}
    {n : Nat} {s : MState W} {res : TermOutcome W}
    (hab : SrcAbout G src si svid.val facts.val savail o args env sc sj n s res)
    {tc : Nat} {Bt : Block} {ts : MState W} {schain : List Std.I32}
    (htin : TIn G tgt ti tvid.val tavail env tc Bt ts Bt.insts.val.length schain)
    {tj : Std.I32} (htj : EdgeTaken o ts.regs Bt.term tj) (_hw : ts.world = s.world)
    {g g' : ValGraph} (hedge : edge_ok g src svid facts tgt tvid (i32n sc) (i32n tc) sj tj = ok (true, g'))
    (hgd : ValGraphDAG g) (hgG : vg_extends g' G) (hgs : VidsOK g svid.val) (hgt : VidsOK g tvid.val)
    (hgf : ∀ fb ∈ facts.val, Valid g fb.vid)
    {gh gh' : ValGraph} (hhead : head_ok gh src svid tgt tvid sj tj = ok (true, gh')) (hghG : vg_extends gh G)
    (hghs : VidsOK gh svid.val) (hght : VidsOK gh tvid.val)
    (hbm : ∃ j : Nat, bm_t[j]? = some tj ∧ bm_s[j]? = some sj) :
    ∃ n' Bj R env' Btj R', n = n' + 1 ∧ src.blocks.val[sj.val.toNat]? = some Bj ∧
      SIn G src si svid.val facts.val savail o args env' sj.val.toNat Bj { regs := R, world := s.world }
        { regs := R, world := s.world } 0 ∧
      SHist G src si svid.val facts.val savail o env' sj.val.toNat ∧
      restFrom o args src n' sj.val.toNat Bj 0 { regs := R, world := s.world } = some res ∧
      tgt.blocks.val[tj.val.toNat]? = some Btj ∧ execPhis o ts.regs tc Btj.phis.val ts.regs = some R' ∧
      TIn G tgt ti tvid.val tavail env' tj.val.toNat Btj { ts with regs := R' } 0 [sj] ∧ 0 ≤ tj.val := by
  have hlen := CS.wf.len_le
  have tlen := CT.wf.len_le
  obtain ⟨n', Bj, R, hn, hBj, hR, hin, hhist', hrun⟩ := src_enter_about CS hab
  obtain ⟨hend, hhist, ⟨Bsc, hBsc, hsedge⟩, hsj0, -, hsym, hpar⟩ := hab
  let env' := enterEnv o args env sj Bj sc s.regs { regs := R, world := s.world }
  have hag : AgreeExcept sj env env' := enterEnv_agree o args env sj Bj sc s.regs _
  obtain ⟨hreach_sc, hfacts_sc, Bsc', hBsc', hregs_sc⟩ := hend
  rw [hBsc] at hBsc'; cases hBsc'
  have hscl : sc < src.blocks.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hBsc; cases hBsc
  have hscn : (i32n sc).val.toNat = sc := i32n_toNat (by omega)
  have hscv : (i32n sc).val = sc := i32n_val (by omega)
  have htcl : tc < tgt.blocks.val.length := by
    have := htin.blk; by_contra hc; rw [List.getElem?_eq_none (by omega)] at this; cases this
  have htcv : (i32n tc).val = tc := i32n_val (by omega)
  obtain ⟨-, -, hsterm, hssucc⟩ := CS.block sc Bsc hreach_sc hBsc
  obtain ⟨-, -, -, S, hS, hsarms⟩ := hssucc sj (edgeTaken_mem hsedge)
  rw [hBj] at hS; cases hS
  obtain ⟨-, -, -, htsucc⟩ := CT.block tc Bt htin.reach htin.blk
  obtain ⟨htj0, htjl, -, T, hT, htarms⟩ := htsucc tj (edgeTaken_mem htj)
  obtain ⟨e', -, Btj, hBtj, hedgeP⟩ := edge_ok_sound hedge rfl hgd hgs hgt hgf
  rw [hT] at hBtj; cases hBtj
  obtain ⟨Btj', hBtj', hheadP⟩ := head_ok_sound hhead rfl
  rw [hT] at hBtj'; cases hBtj'
  have hgG' : vg_extends g G := vg_extends_trans e' hgG
  have hphisT : ∀ P ∈ T.phis.val, ∃ a, phiArg P tc = some a ∧
      ∀ v, tvid.val[P.dst.val.toNat]? = some v → Valid G v → atomVal o ts.regs P.cls a = evI G env' v := by
    intro P hP
    obtain ⟨ta, hta, hsem⟩ := hedgeP G hgG P hP
    refine ⟨ta, by rw [htcv] at hta; exact hta, fun v hv hvv => ?_⟩
    obtain ⟨a, ha, haAv⟩ := htarms P hP
    rw [htcv] at hta
    rw [ha] at hta
    have eat : a = ta := Option.some.inj hta
    subst eat
    have hagt : AtomAgree G env tvid.val o ts.regs a := agree_of_avail htin.regs hsym haAv
    have hfb : ∀ fb ∈ facts.val, fb.blk = i32n sc → FactOK G env fb :=
      fun fb hm he => hfacts_sc fb hm (by rw [he, hscv])
    obtain ⟨hcase, hncase⟩ := hsem o env s.regs ts.regs Bsc (by omega) (by rw [hscn]; exact hBsc)
      (condAgree_of_avail hregs_sc hsym hsterm) hsedge hfb hagt
    obtain ⟨v', hv', hd0, hvv', hS1, hS2⟩ := hheadP P hP
    rw [hv] at hv'; cases hv'
    have hiff := srcPhiCase_iff hghG hghs (src := src) (sh := sj) (d := P.dst)
    by_cases hc : SrcPhiCase G src svid.val sj P.dst
    · obtain ⟨k, Bs, SP, sa, hfk, hk0, hBs, hSP, hsa, hval⟩ := hcase hc
      rw [hBj] at hBs; cases hBs
      obtain ⟨k', Bs', SP', hfk', hk0', hBs', hSP', hcls, hsv⟩ := hS1 (hiff.1 hc)
      rw [hfk] at hfk'; cases ok_inj' hfk'
      rw [hBj] at hBs'; cases hBs'
      rw [hSP] at hSP'; cases hSP'
      obtain ⟨Bx, P2, hBx, hP2, hP2d⟩ := find_phi_spec hfk hk0
      rw [hBj] at hBx; cases hBx
      rw [hSP] at hP2; cases hP2
      have hSPm : SP ∈ Bj.phis.val := List.mem_of_getElem? hSP
      obtain ⟨a', ha', haAv'⟩ := hsarms SP hSPm
      rw [hscv] at hsa
      rw [hsa] at ha'
      have esa := Option.some.inj ha'
      subst esa
      rw [hval (agree_of_avail hregs_sc hsym haAv')]
      have hsj' : i32n sj.val.toNat = sj := (i32n_of_val hsj0).symm
      have hphi := src_phi_sem CS ⟨hreach_sc, hfacts_sc, Bsc, hBsc, hregs_sc⟩ hhist hsym hBsc hBj
        (by rw [hsj']; exact hsedge) (by rw [hsj']; exact hag)
        (fun c k P hk => by rw [hsj']; exact enterEnv_phi o args env sj Bj sc s.regs _ c k P hk)
        k.val.toNat SP hSP v (by rw [hP2d]; exact hsv)
      rw [hphi]
      simp only [phiValAt, hsa, hcls]
    · rw [← hncase hc v hv hvv]
      have hmen := hS2 (fun h => hc (hiff.2 h))
      have hvgh : Valid gh v := by
        rcases hght _ v hv with rfl | h'
        · exact absurd hvv.1 (by simp)
        · exact h'
      have := vid_mentions_blk_sound hmen hvgh.1 hag
      rw [extends_evI hghG env' hvgh, extends_evI hghG env hvgh]
      exact this.symm
  have hstT : ∀ x, x < ti.nt.val.toNat → AvB tavail ti.nt tj.val.toNat x → ∀ v, tvid.val[x]? = some v →
      Valid G v → evI G env' v = evI G env v := by
    intro x hx hav v hv hvv
    obtain ⟨j, hj1, hj2⟩ := hbm
    have htjn : tj = i32n tj.val.toNat := i32n_of_val htj0.le
    have hreach_tj : ti.reach.val[tj.val.toNat]? = some true :=
      CT.info.closed tc Bt htin.blk htin.reach tj (edgeTaken_mem htj) (by omega) htjl
    exact CT.scope tj.val.toNat hreach_tj (by omega) j sj (by rw [← htjn]; exact hj1) hj2 x hx hav v hv hvv.1 env env' hag
  obtain ⟨R', hR', htin'⟩ := tgt_enter CT (schain' := [sj]) htin htj hT hphisT hstT
  exact ⟨n', Bj, R, env', T, R', hn, hBj, hin, hhist', hrun, hT, hR', htin', htj0.le⟩

/-! ## One step of the replay -/

/-- The value graph of a replay: acyclic, with the certificate's ids and facts. -/
def GPre (cert : Cert) (g : ValGraph) : Prop :=
  ValGraphDAG g ∧ VidsOK g cert.svid.val ∧ VidsOK g cert.tvid.val ∧ ∀ fb ∈ cert.facts.val, Valid g fb.vid

theorem gPre_ext {cert : Cert} {g g' : ValGraph} (hp : vg_extends g g') (hd : ValGraphDAG g') (h : GPre cert g) :
    GPre cert g' :=
  ⟨hd, vidsOK_extends hp h.2.1, vidsOK_extends hp h.2.2.1, fun fb hm => extends_valid hp (h.2.2.2 fb hm)⟩

theorem factsHold_of_facts_of {G : ValGraph} {env : SymEnv} {facts : Pion.Array Fact} {b : Std.I32}
    {fs : Pion.Array Fact} (hfs : facts_of facts b = ok fs)
    (h : ∀ fa ∈ facts.val, fa.blk.val = b.val.toNat → FactOK G env fa) (hb : 0 ≤ b.val) :
    FactsHold G env fs.val := by
  intro fa hfa
  obtain ⟨hm, he⟩ := mem_facts_of hfs hfa
  exact h fa hm (by rw [he]; omega)

/-- The state after the instructions a replay step runs, before the blocks it may enter. -/
def MidState (G : ValGraph) (src tgt : Func) (cert : Cert) (si ti : FnInfo) {W : Type}
    (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W) (env : SymEnv) (n : Nat)
    (sc tc : Nat) (Bs Bt : Block) (s0 : MState W) (sx4 tx3 : Nat) (sj4 tj3 : Std.I32)
    (schain : List Std.I32) (ts1 : MState W) (tx1 : Nat) : Prop :=
  ∃ (s2 ts2 : MState W),
    ((sj4.val < 0 ∧ SIn G src si cert.svid.val cert.facts.val cert.savail o args env sc Bs s0 s2 sx4 ∧
        restFrom o args src n sc Bs sx4 s2 = some res ∧ ts2.world = s2.world) ∨
     (0 ≤ sj4.val ∧ ∃ prev n' s', SrcAbout G src si cert.svid.val cert.facts.val cert.savail o args env prev sj4 n' s' res ∧
        n' ≤ n ∧ s'.world = ts2.world)) ∧
    TIn G tgt ti cert.tvid.val cert.tavail env tc Bt ts2 tx3 schain ∧
    (tj3.val < 0 ∨ (0 ≤ tj3.val ∧ tx3 = Bt.insts.val.length ∧ EdgeTaken o ts2.regs Bt.term tj3)) ∧
    (∀ m, restFrom o args tgt m tc Bt tx3 ts2 = some res → restFrom o args tgt m tc Bt tx1 ts1 = some res)

/-- The runs at a point of a pair's replay: the source in block `sc` before instruction `sx`, the
target in block `tc` before instruction `tx`, the source with at most `N` blocks of run left. -/
def RState (G : ValGraph) (src tgt : Func) (cert : Cert) (si ti : FnInfo) {W : Type}
    (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W) (N : Nat)
    (sc sx tc tx : Std.I32) (schain : Pion.Array Std.I32) (env : SymEnv) (n : Nat) (s0 s ts : MState W) : Prop :=
  0 ≤ sc.val ∧ 0 ≤ sx.val ∧ 0 ≤ tc.val ∧ 0 ≤ tx.val ∧ n ≤ N ∧ sc ∈ schain.val ∧ EnvOK o args env ∧
  ts.world = s.world ∧ (∀ x ∈ schain.val, 0 ≤ x.val) ∧
  ∃ Bs Bt, SIn G src si cert.svid.val cert.facts.val cert.savail o args env sc.val.toNat Bs s0 s sx.val.toNat ∧
    SHist G src si cert.svid.val cert.facts.val cert.savail o env sc.val.toNat ∧
    restFrom o args src n sc.val.toNat Bs sx.val.toNat s = some res ∧
    TIn G tgt ti cert.tvid.val cert.tavail env tc.val.toNat Bt ts tx.val.toNat schain.val

/-- The target, from block `tc` before instruction `tx`, ends with `res`. -/
def TGoal (tgt : Func) {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
    (tc tx : Std.I32) (ts : MState W) : Prop :=
  ∃ Bt m, tgt.blocks.val[tc.val.toNat]? = some Bt ∧ restFrom o args tgt m tc.val.toNat Bt tx.val.toNat ts = some res

theorem tin_mono_chain {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {env : SymEnv} {tb : Nat} {Bt : Block} {W : Type} {ts : MState W} {tx : Nat}
    {schain schain' : List Std.I32} (hin : TIn G tgt ti tvid tavail env tb Bt ts tx schain)
    (hsub : ∀ x ∈ schain, x ∈ schain') : TIn G tgt ti tvid tavail env tb Bt ts tx schain' :=
  tin_reenv hin (fun _ _ _ _ _ => rfl) hsub

theorem push_val {α : Type} (a : Pion.Array α) (x : α) : (Pion.Array.push a x).val = a.val ++ [x] := rfl

/-- The runs after the pure instructions a replay step skips. -/
def AfterSkip (G : ValGraph) (src tgt : Func) (cert : Cert) (si ti : FnInfo) {W : Type}
    (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W) (env : SymEnv) (n : Nat)
    (sc tc : Nat) (Bs Bt : Block) (s0 s1 ts1 : MState W) (sx1 tx1 : Nat) (schain : List Std.I32) : Prop :=
  SIn G src si cert.svid.val cert.facts.val cert.savail o args env sc Bs s0 s1 sx1 ∧
  restFrom o args src n sc Bs sx1 s1 = some res ∧
  SHist G src si cert.svid.val cert.facts.val cert.savail o env sc ∧
  TIn G tgt ti cert.tvid.val cert.tavail env tc Bt ts1 tx1 schain ∧ ts1.world = s1.world ∧ EnvOK o args env

/-- Source and target views of the terminators, once their instructions are done. -/
theorem views_hold {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {res : TermOutcome W} {env : SymEnv} {n : Nat}
    {sc tc : Std.I32} {Bs Bt : Block} {s0 s1 ts1 : MState W} {sx1 tx1 : Nat} {schain : List Std.I32}
    (hsc0 : 0 ≤ sc.val) {fs : Pion.Array Fact} (hfs : facts_of cert.facts sc = ok fs)
    (ha : AfterSkip G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 s1 ts1 sx1 tx1 schain) :
    FactsHold G env fs.val ∧
    (sx1 = Bs.insts.val.length → TermAgree G env cert.svid.val o s1.regs Bs.term) ∧
    (tx1 = Bt.insts.val.length → TermAgree G env cert.tvid.val o ts1.regs Bt.term) := by
  obtain ⟨hin, -, -, htin, -, henv⟩ := ha
  refine ⟨factsHold_of_facts_of hfs hin.facts hsc0, fun he => ?_, fun he => ?_⟩
  · obtain ⟨-, -, ht, -⟩ := CS.block _ Bs hin.reach hin.blk
    have hr := hin.regs
    rw [he] at hr
    exact termAgree_of_avail hr henv.1 ht
  · obtain ⟨-, -, ht, -⟩ := CT.block _ Bt htin.reach htin.blk
    have hr := htin.regs
    rw [he] at hr
    exact termAgree_of_avail hr henv.1 ht

theorem i32_toNat_succ {x : Std.I32} {n : Nat} (h : x.val.toNat < n) (hn : n ≤ 2147483647) (h0 : 0 ≤ x.val) :
    (Pion.I32.add x 1#i32).val = x.val + 1 ∧ (Pion.I32.add x 1#i32).val.toNat = x.val.toNat + 1 := by
  have := i32_succ_val' (m := n) (i := x) (by omega) hn
  exact ⟨this, by omega⟩

/-- The instructions one replay step runs (`MatchEff`, `SkipSrcReadOnly`) or the terminator views
it takes (`SrcJmp`, `SrcJoin`, `TgtJmp`, `BothJmp`). -/
theorem action_sim {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val)
    {g vg1 : ValGraph} {sc tc sx1 tx1 : Std.I32} {Bs Bt : Block} {nsi nti : Std.I32}
    {fs : Pion.Array Fact} (st : Step) {r : Sum (Std.I32 × ValGraph) (ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32)}
    {vg9 : ValGraph} {sx4 tx3 sj4 tj3 : Std.I32}
    (hsc0 : 0 ≤ sc.val) (_htc0 : 0 ≤ tc.val) (hsx0 : 0 ≤ sx1.val) (htx0 : 0 ≤ tx1.val)
    (hBs : Pion.Array.get src.blocks sc = ok Bs) (hBt : Pion.Array.get tgt.blocks tc = ok Bt)
    (hnsi : Pion.Array.length Bs.insts = ok nsi) (hnti : Pion.Array.length Bt.insts = ok nti)
    (hfs : facts_of cert.facts sc = ok fs) (hg1 : GPre cert vg1) (hgg1 : vg_extends g vg1)
    (hgs : VidsOK g cert.svid.val)
    (heff : ∀ hx : sx1.val.toNat < Bs.insts.val.length,
      src_inst_is_effect g cert.svid Bs.insts.val[sx1.val.toNat] sc sx1 = ok true)
    (hr : r = .inr (vg9, sx4, tx3, sj4, tj3))
    (hst : (match (generalizing := false) st with
      | .MatchEff => do
        let (t20, vg2) ← do
          if ((!(decide (sx1 < nsi))) || (!(decide (tx1 < nti)))) then ok (true, vg1)
          else do
            let a ← Pion.Array.get src.blocks sc
            let b ← Pion.Array.get a.insts sx1
            let c ← Pion.Array.get tgt.blocks tc
            let d ← Pion.Array.get c.insts tx1
            let (t19, vg3) ← match_effect_c vg1 cert.svid cert.tvid fs b d
            ok ((!t19), vg3)
        if t20 then ok (.inl (3#i32, vg2))
        else ok (.inr (vg2, Pion.I32.add sx1 1#i32, Pion.I32.add tx1 1#i32, (-1)#i32, (-1)#i32))
      | .SkipSrcReadOnly => do
        let t24 ← do
          if (!(decide (sx1 < nsi))) then ok true
          else do
            let a ← Pion.Array.get src.blocks sc
            let b ← Pion.Array.get a.insts sx1
            let c ← src_skippable b
            ok (!c)
        if t24 then ok (.inl (4#i32, vg1))
        else ok (.inr (vg1, Pion.I32.add sx1 1#i32, tx1, (-1)#i32, (-1)#i32))
      | .SrcJmp =>
        if (decide (sx1 < nsi)) then ok (.inl (5#i32, vg1))
        else do
          let (v, vg4) ← src_view vg1 src cert.svid fs sc
          let sj1 ← view_jmp v
          ok (.inr (vg4, sx1, tx1, sj1, (-1)#i32))
      | .SrcJoin =>
        if (decide (sx1 < nsi)) then ok (.inl (6#i32, vg1))
        else do
          let (v, vg5) ← src_view vg1 src cert.svid fs sc
          match v with
          | .VJnz _ _ _ => do
            let sj2 ← src_join src sc
            ok (.inr (vg5, sx1, tx1, sj2, (-1)#i32))
          | _ => ok (.inl (7#i32, vg5))
      | .TgtJmp =>
        if (decide (tx1 < nti)) then ok (.inl (8#i32, vg1))
        else do
          let (v, vg6) ← tgt_view_c vg1 tgt cert.tvid fs tc
          let tj1 ← view_jmp v
          ok (.inr (vg6, sx1, tx1, (-1)#i32, tj1))
      | .BothJmp =>
        if ((decide (sx1 < nsi)) || (decide (tx1 < nti))) then ok (.inl (9#i32, vg1))
        else do
          let (v, vg7) ← src_view vg1 src cert.svid fs sc
          let sj3 ← view_jmp v
          let (w, vg8) ← tgt_view_c vg7 tgt cert.tvid fs tc
          let tj2 ← view_jmp w
          if ((decide (sj3 < 0#i32)) || (decide (tj2 < 0#i32))) then ok (.inl (10#i32, vg8))
          else ok (.inr (vg8, sx1, tx1, sj3, tj2))) = ok r) :
    vg_extends vg1 vg9 ∧ GPre cert vg9 ∧ 0 ≤ sx4.val ∧ 0 ≤ tx3.val ∧
      (vg_extends vg9 G → ∀ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
        (env : SymEnv) (n : Nat) (s0 s1 ts1 : MState W) (schain : List Std.I32),
        sc ∈ schain →
        AfterSkip G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 s1 ts1
          sx1.val.toNat tx1.val.toNat schain →
        MidState G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 sx4.val.toNat
          tx3.val.toNat sj4 tj3 schain ts1 tx1.val.toNat) := by
  subst hr
  obtain ⟨hnsi1, hnsi2⟩ := arr_length_ok hnsi
  obtain ⟨hnti1, hnti2⟩ := arr_length_ok hnti
  have hsh : decide (sx1 < nsi) = true ↔ sx1.val.toNat < Bs.insts.val.length := by
    simp only [decide_eq_true_eq, i32_lt_iff, hnsi1]; omega
  have hth : decide (tx1 < nti) = true ↔ tx1.val.toNat < Bt.insts.val.length := by
    simp only [decide_eq_true_eq, i32_lt_iff, hnti1]; omega
  -- staying put: the runs are where the skips left them
  have stay : ∀ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
      (env : SymEnv) (n : Nat) (s0 s1 ts1 : MState W) (schain : List Std.I32),
      AfterSkip G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 s1 ts1
        sx1.val.toNat tx1.val.toNat schain →
      MidState G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 sx1.val.toNat
        tx1.val.toNat ((-1)#i32) ((-1)#i32) schain ts1 tx1.val.toNat := by
    intro W o args res env n s0 s1 ts1 schain ha
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    exact ⟨s1, ts1, Or.inl ⟨by simp, hin, hrun, hw⟩, htin, Or.inl (by simp), fun m h => h⟩
  have hvj : ∀ v : TView, view_jmp v = ok (match v with | .VJmp s => s | _ => (-1)#i32) := view_jmp_spec
  cases st with
  | MatchEff =>
    simp only at hst
    obtain ⟨q2, hq2, h1⟩ := bind_eq_ok hst
    obtain ⟨t20, vg2⟩ := q2
    try simp only [uncurry_apply_pair] at h1
    cases t20 with
    | true => simp only [↓reduceIte] at h1; cases ok_inj' h1
    | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h1
    have e1 := ok_inj' h1
    simp only [Sum.inr.injEq, Prod.mk.injEq] at e1
    obtain ⟨e9, es, et, ej, ek⟩ := e1
    subst e9 es et ej ek
    by_cases hcond : ((!(decide (sx1 < nsi))) || (!(decide (tx1 < nti)))) = true
    · rw [ite_eq_left hcond] at hq2; cases ok_inj' hq2
    rw [ite_eq_right hcond] at hq2
    have hsx : sx1.val.toNat < Bs.insts.val.length := hsh.1 (by revert hcond; cases decide (sx1 < nsi) <;> simp)
    have htx : tx1.val.toNat < Bt.insts.val.length := hth.1 (by
      revert hcond; cases decide (sx1 < nsi) <;> cases decide (tx1 < nti) <;> simp)
    obtain ⟨a, ha, hq3⟩ := bind_eq_ok hq2
    rw [hBs] at ha; cases ok_inj' ha
    obtain ⟨b, hb, hq4⟩ := bind_eq_ok hq3
    obtain ⟨-, hbl, hbv⟩ := arr_get_ok hb
    obtain ⟨c, hc, hq5⟩ := bind_eq_ok hq4
    rw [hBt] at hc; cases ok_inj' hc
    obtain ⟨d, hd, hq6⟩ := bind_eq_ok hq5
    obtain ⟨-, hdl, hdv⟩ := arr_get_ok hd
    obtain ⟨q7, hq7, hq8⟩ := bind_eq_ok hq6
    obtain ⟨t19, vg3⟩ := q7
    try simp only [uncurry_apply_pair] at hq8
    have e8 := ok_inj' hq8
    simp only [Prod.mk.injEq] at e8
    obtain ⟨et19, eg⟩ := e8
    have ht19 : t19 = true := by revert et19; cases t19 <;> simp
    subst ht19 eg
    rw [← hbv, ← hdv] at hq7
    obtain ⟨e2, d2, hEff⟩ := match_effect_c_sound hq7 rfl hg1.1 hg1.2.1 hg1.2.2.1
    dsimp only at e2 d2 hEff
    obtain ⟨hs1, hs1'⟩ := i32_toNat_succ hsx hnsi2 hsx0
    obtain ⟨ht1, ht1'⟩ := i32_toNat_succ htx hnti2 htx0
    refine ⟨e2, gPre_ext e2 d2 hg1, by omega, by omega, fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    obtain ⟨hfsh, -, -⟩ := views_hold CS CT hsc0 hfs ⟨hin, hrun, hhist, htin, hw, henv⟩
    rw [restFrom_step o args src hsx] at hrun
    cases hex : execInst o args s1 Bs.insts.val[sx1.val.toNat] with
    | none => rw [hex] at hrun; simp at hrun
    | some s2 =>
    rw [hex, Option.bind_some] at hrun
    have hin2 := src_inst_step CS hin hsx hex
    obtain ⟨-, hinsts, -, -⟩ := CS.block _ Bs hin.reach hin.blk
    obtain ⟨-, tinsts, -, -⟩ := CT.block _ Bt htin.reach htin.blk
    have hos := opsAgree_of_avail hin.regs henv.1 (hinsts _ hsx).1
    have hot := opsAgree_of_avail htin.regs henv.1 (tinsts _ htx).1
    obtain ⟨ts2, hexT, hwT, hdst⟩ := hEff G hG o args env hfsh s1 ts1 s2 hos hot hw.symm hex
    have hsdefs := CS.defs sc hsc0 Bs (by rw [show (sc.val.toNat) = sc.val.toNat from rfl]; exact hin.blk)
    have htin2 := tgt_step CT htin htx hexT (fun v hd0 hv hvv => ?_)
    · refine ⟨s2, ts2, Or.inl ⟨by simp, by rw [hs1']; exact hin2, by rw [hs1']; exact hrun, by rw [hwT]⟩,
        by rw [ht1']; exact htin2, Or.inl (by simp), fun m hm => ?_⟩
      rw [restFrom_step o args tgt htx, hexT, Option.bind_some]
      rw [ht1'] at hm
      exact hm
    · rcases hdst with hneg | ⟨w, hsd0, htd0, hsw, hw0, htw, hreg⟩
      · omega
      rw [htw] at hv
      have evw := Option.some.inj hv
      subst evw
      have hsdt : CurAt si.nt.val.toNat (AvB cert.savail si.nt sc.val.toNat) Bs (sx1.val.toNat + 1)
          (instDst Bs.insts.val[sx1.val.toNat]).val.toNat := by
        have hlt := (hinsts _ hsx).2 hsd0
        have := CS.nt0
        refine ⟨by omega, Or.inr (Or.inr ⟨sx1.val.toNat, by omega, hsx, by omega⟩)⟩
      refine ⟨by rw [hreg]; exact hin2.regs _ hsdt w hsw hvv, Or.inr ?_⟩
      -- the matched source result is a leaf of the current source block
      have hsxn : sx1 = i32n sx1.val.toNat := i32n_of_val hsx0
      have hscn : sc = i32n sc.val.toNat := i32n_of_val hsc0
      obtain ⟨-, -, hidefs⟩ := hsdefs
      obtain ⟨w', hw', hvw', hcase⟩ := hidefs sx1 hsx0 hsx hsd0
      rw [hsw] at hw'; cases hw'
      have heff' := heff hsx
      generalize hI : Bs.insts.val[sx1.val.toNat] = I at hcase hq7 hexT heff' hsd0 hsw
      cases I with
      | Bin dd cc op aa bb =>
        obtain ⟨-, hdis⟩ := src_inst_is_effect_bin heff'
        simp only [instDst] at hsd0 hsw
        rcases hdis with h' | h' | h' | ⟨v', hv', hn⟩
        · omega
        · rw [List.getElem?_eq_none h'] at hsw; cases hsw
        · exact absurd ((hgs _ w hsw).resolve_left (by intro e; rw [e] at hw0; simp at hw0)) (h' w hsw)
        · rw [hsw] at hv'; cases hv'
          have hext := extends_nodeAt (vg_extends_trans hgg1 (vg_extends_trans e2 hG)) (nodeAt_valid hn)
          exact ⟨cc, sc, sx1, hsc, by rw [hext]; exact hn⟩
      | Load dd cc w sg aa =>
        rcases hcase with hp | ⟨-, hn⟩
        · exact absurd hp (by simp [PureDef])
        · exact ⟨_, _, _, hsc, hn⟩
      | Call dd cc hh cal cargs =>
        rcases hcase with hp | ⟨-, hn⟩
        · exact absurd hp (by simp [PureDef])
        · exact ⟨_, _, _, hsc, hn⟩
      | Alloc dd al sz =>
        rcases hcase with hp | ⟨-, hn⟩
        · exact absurd hp (by simp [PureDef])
        · exact ⟨_, _, _, hsc, hn⟩
      | Store _ _ _ => simp [instDst] at hsd0
      | Par _ _ _ => simp [match_effect_c] at hq7
      | Un _ _ _ _ => simp [match_effect_c] at hq7
  | SkipSrcReadOnly =>
    simp only at hst
    obtain ⟨t24, ht24, h1⟩ := bind_eq_ok hst
    cases t24 with
    | true => simp only [↓reduceIte] at h1; cases ok_inj' h1
    | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at h1
    have e1 := ok_inj' h1
    simp only [Sum.inr.injEq, Prod.mk.injEq] at e1
    obtain ⟨e9, es, et, ej, ek⟩ := e1
    subst e9 es et ej ek
    by_cases hcond : (!(decide (sx1 < nsi))) = true
    · rw [ite_eq_left hcond] at ht24; cases ok_inj' ht24
    rw [ite_eq_right hcond] at ht24
    have hsx : sx1.val.toNat < Bs.insts.val.length := hsh.1 (by revert hcond; cases decide (sx1 < nsi) <;> simp)
    obtain ⟨a, ha, h2⟩ := bind_eq_ok ht24
    rw [hBs] at ha; cases ok_inj' ha
    obtain ⟨b, hb, h3⟩ := bind_eq_ok h2
    obtain ⟨-, hbl, hbv⟩ := arr_get_ok hb
    obtain ⟨t23, ht23, h4⟩ := bind_eq_ok h3
    have ht23t : t23 = true := by revert h4; cases t23 <;> simp
    subst ht23t
    obtain ⟨hs1, hs1'⟩ := i32_toNat_succ hsx hnsi2 hsx0
    refine ⟨vg_extends_refl _, hg1, by omega, htx0, fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    rw [restFrom_step o args src hsx] at hrun
    cases hex : execInst o args s1 Bs.insts.val[sx1.val.toNat] with
    | none => rw [hex] at hrun; simp at hrun
    | some s2 =>
    rw [hex, Option.bind_some] at hrun
    have hin2 := src_inst_step CS hin hsx hex
    have hw2 : s2.world = s1.world := by
      rw [← hbv] at ht23
      generalize hI : Bs.insts.val[sx1.val.toNat] = I at ht23 hex
      cases I with
      | Load dd cc w sg aa => exact execInst_load_world hex
      | Bin dd cc op aa bb => exact execInst_world (show NoWorld (Inst.Bin dd cc op aa bb) from trivial) hex
      | _ => simp [src_skippable] at ht23
    exact ⟨s2, ts1, Or.inl ⟨by simp, by rw [hs1']; exact hin2, by rw [hs1']; exact hrun, by rw [hw2, hw]⟩,
      htin, Or.inl (by simp), fun m hm => hm⟩
  | SrcJmp =>
    simp only at hst
    by_cases hcond : decide (sx1 < nsi) = true
    · rw [ite_eq_left hcond] at hst; cases ok_inj' hst
    rw [ite_eq_right hcond] at hst
    obtain ⟨q4, hq4, h1⟩ := bind_eq_ok hst
    obtain ⟨v, vg4⟩ := q4
    try simp only [uncurry_apply_pair] at h1
    obtain ⟨sj1, hsj1, h2⟩ := bind_eq_ok h1
    rw [hvj] at hsj1
    have e2 := ok_inj' h2
    simp only [Sum.inr.injEq, Prod.mk.injEq] at e2
    obtain ⟨e9, es, et, ej, ek⟩ := e2
    subst e9 es et ej ek
    obtain ⟨e4, d4, B', hB', -, -, hview⟩ := src_view_sound hq4 hg1.1 hg1.2.1
    dsimp only at e4 d4 hview
    obtain ⟨-, hBl, hBv⟩ := arr_get_ok hBs
    rw [List.getElem?_eq_getElem hBl, hBv] at hB'; cases hB'
    refine ⟨e4, gPre_ext e4 d4 hg1, hsx0, htx0, fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
    obtain ⟨hfsh, hta, -⟩ := views_hold CS CT hsc0 hfs ha
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    have hsxe : sx1.val.toNat = Bs.insts.val.length := by
      have := mt hsh.2 hcond; have := hin.le; omega
    have hV := hview G hG o s1.regs env hfsh (hta hsxe)
    cases v with
    | VJmp sj =>
      simp only at hsj1
      cases ok_inj' hsj1
      by_cases hsj0 : 0 ≤ sj1.val
      · rw [hsxe] at hin hrun
        exact ⟨s1, ts1, Or.inr ⟨hsj0, sc.val.toNat, n, s1, src_leave hin hhist hrun hV, le_refl _, hw.symm⟩,
          htin, Or.inl (by simp), fun m hm => hm⟩
      · exact ⟨s1, ts1, Or.inl ⟨by omega, hin, hrun, hw⟩, htin, Or.inl (by simp), fun m hm => hm⟩
    | _ =>
      simp only at hsj1
      cases ok_inj' hsj1
      exact ⟨s1, ts1, Or.inl ⟨by simp, hin, hrun, hw⟩, htin, Or.inl (by simp), fun m hm => hm⟩
  | SrcJoin =>
    simp only at hst
    by_cases hcond : decide (sx1 < nsi) = true
    · rw [ite_eq_left hcond] at hst; cases ok_inj' hst
    rw [ite_eq_right hcond] at hst
    obtain ⟨q5, hq5, h1⟩ := bind_eq_ok hst
    obtain ⟨v, vg5⟩ := q5
    try simp only [uncurry_apply_pair] at h1
    obtain ⟨e5, d5, B', hB', -, -, hview⟩ := src_view_sound hq5 hg1.1 hg1.2.1
    dsimp only at e5 d5 hview
    obtain ⟨-, hBl, hBv⟩ := arr_get_ok hBs
    rw [List.getElem?_eq_getElem hBl, hBv] at hB'; cases hB'
    cases v with
    | VJnz cs s1' s2' =>
      simp only at h1
      obtain ⟨sj2, hsj2, h2⟩ := bind_eq_ok h1
      have e2 := ok_inj' h2
      simp only [Sum.inr.injEq, Prod.mk.injEq] at e2
      obtain ⟨e9, es, et, ej, ek⟩ := e2
      subst e9 es et ej ek
      refine ⟨e5, gPre_ext e5 d5 hg1, hsx0, htx0, fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
      obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
      have hsxe : sx1.val.toNat = Bs.insts.val.length := by
        have := mt hsh.2 hcond; have := hin.le; omega
      by_cases hsj0 : 0 ≤ sj2.val
      · obtain ⟨B2, c, r1, r2, hB2, -, hT, hr1, hr2⟩ := src_join_sound hsj2 hsj0
        obtain ⟨-, hBl2, hBv2⟩ := arr_get_ok hBs
        rw [List.getElem?_eq_getElem hBl2, hBv2] at hB2; cases hB2
        rw [hsxe] at hin hrun
        -- the source leaves along one arm of its `jnz`, then runs empty blocks to the join
        have hleave : ∀ e, EdgeTaken o s1.regs Bs.term e → TrivReach src e sj2 →
            MidState G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 sx1.val.toNat
              tx1.val.toNat sj2 ((-1)#i32) schain ts1 tx1.val.toNat := by
          intro e he hreach
          obtain ⟨prev', n', s', ha', hn', hw'⟩ := triv_run CS hreach sc.val.toNat n s1 (src_leave hin hhist hrun he)
          exact ⟨s1, ts1, Or.inr ⟨hsj0, prev', n', s', ha', hn', by rw [hw', hw]⟩, htin, Or.inl (by simp),
            fun m hm => hm⟩
        by_cases hcv : atomVal o s1.regs .W c ≠ 0
        · exact hleave r1 (by rw [hT]; simp only [EdgeTaken]; rw [ite_eq_left hcv]) hr1
        · exact hleave r2 (by rw [hT]; simp only [EdgeTaken]; rw [ite_eq_right hcv]) hr2
      · exact ⟨s1, ts1, Or.inl ⟨by omega, hin, hrun, hw⟩, htin, Or.inl (by simp), fun m hm => hm⟩
    | _ => simp only at h1; cases ok_inj' h1
  | TgtJmp =>
    simp only at hst
    by_cases hcond : decide (tx1 < nti) = true
    · rw [ite_eq_left hcond] at hst; cases ok_inj' hst
    rw [ite_eq_right hcond] at hst
    obtain ⟨q6, hq6, h1⟩ := bind_eq_ok hst
    obtain ⟨v, vg6⟩ := q6
    try simp only [uncurry_apply_pair] at h1
    obtain ⟨tj1, htj1, h2⟩ := bind_eq_ok h1
    rw [hvj] at htj1
    have e2 := ok_inj' h2
    simp only [Sum.inr.injEq, Prod.mk.injEq] at e2
    obtain ⟨e9, es, et, ej, ek⟩ := e2
    subst e9 es et ej ek
    rw [tgt_view_c_eq] at hq6
    obtain ⟨e6, d6, B', hB', -, -, hview⟩ := src_view_sound hq6 hg1.1 hg1.2.2.1
    dsimp only at e6 d6 hview
    obtain ⟨-, hBl, hBv⟩ := arr_get_ok hBt
    rw [List.getElem?_eq_getElem hBl, hBv] at hB'; cases hB'
    refine ⟨e6, gPre_ext e6 d6 hg1, hsx0, htx0, fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
    obtain ⟨hfsh, -, hta⟩ := views_hold CS CT hsc0 hfs ha
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    have htxe : tx1.val.toNat = Bt.insts.val.length := by
      have := mt hth.2 hcond; have := htin.le; omega
    have hV := hview G hG o ts1.regs env hfsh (hta htxe)
    cases v with
    | VJmp tj =>
      simp only at htj1
      cases ok_inj' htj1
      by_cases htj0 : 0 ≤ tj1.val
      · exact ⟨s1, ts1, Or.inl ⟨by simp, hin, hrun, hw⟩, htin, Or.inr ⟨htj0, htxe, hV⟩, fun m hm => hm⟩
      · exact ⟨s1, ts1, Or.inl ⟨by simp, hin, hrun, hw⟩, htin, Or.inl (by omega), fun m hm => hm⟩
    | _ =>
      simp only at htj1
      cases ok_inj' htj1
      exact ⟨s1, ts1, Or.inl ⟨by simp, hin, hrun, hw⟩, htin, Or.inl (by simp), fun m hm => hm⟩
  | BothJmp =>
    simp only at hst
    by_cases hcond : ((decide (sx1 < nsi)) || (decide (tx1 < nti))) = true
    · rw [ite_eq_left hcond] at hst; cases ok_inj' hst
    rw [ite_eq_right hcond] at hst
    have hsxn : ¬ decide (sx1 < nsi) = true := by revert hcond; cases decide (sx1 < nsi) <;> simp
    have htxn : ¬ decide (tx1 < nti) = true := by
      revert hcond; cases decide (sx1 < nsi) <;> cases decide (tx1 < nti) <;> simp
    obtain ⟨q7, hq7, h1⟩ := bind_eq_ok hst
    obtain ⟨v, vg7⟩ := q7
    try simp only [uncurry_apply_pair] at h1
    obtain ⟨sj3, hsj3, h2⟩ := bind_eq_ok h1
    obtain ⟨q8, hq8, h3⟩ := bind_eq_ok h2
    obtain ⟨w, vg8⟩ := q8
    try simp only [uncurry_apply_pair] at h3
    obtain ⟨tj2, htj2, h4⟩ := bind_eq_ok h3
    rw [hvj] at hsj3 htj2
    by_cases hneg : ((decide (sj3 < 0#i32)) || (decide (tj2 < 0#i32))) = true
    · rw [ite_eq_left hneg] at h4; cases ok_inj' h4
    rw [ite_eq_right hneg] at h4
    have hsj0 : 0 ≤ sj3.val := by
      have : ¬ decide (sj3 < 0#i32) = true := by revert hneg; cases decide (sj3 < 0#i32) <;> simp
      simpa [i32_lt_iff] using this
    have htj0 : 0 ≤ tj2.val := by
      have : ¬ decide (tj2 < 0#i32) = true := by
        revert hneg; cases decide (sj3 < 0#i32) <;> cases decide (tj2 < 0#i32) <;> simp
      simpa [i32_lt_iff] using this
    have e4 := ok_inj' h4
    simp only [Sum.inr.injEq, Prod.mk.injEq] at e4
    obtain ⟨e9, es, et, ej, ek⟩ := e4
    subst e9 es et ej ek
    obtain ⟨e7, d7, B', hB', -, -, hview⟩ := src_view_sound hq7 hg1.1 hg1.2.1
    dsimp only at e7 d7 hview
    rw [tgt_view_c_eq] at hq8
    obtain ⟨e8, d8, B'', hB'', -, -, hview'⟩ := src_view_sound hq8 d7 (vidsOK_extends e7 hg1.2.2.1)
    dsimp only at e8 d8 hview'
    obtain ⟨-, hBl, hBv⟩ := arr_get_ok hBs
    rw [List.getElem?_eq_getElem hBl, hBv] at hB'; cases hB'
    obtain ⟨-, hBl', hBv'⟩ := arr_get_ok hBt
    rw [List.getElem?_eq_getElem hBl', hBv'] at hB''; cases hB''
    refine ⟨vg_extends_trans e7 e8, gPre_ext (vg_extends_trans e7 e8) d8 hg1, hsx0, htx0,
      fun hG W o args res env n s0 s1 ts1 schain hsc ha => ?_⟩
    obtain ⟨hfsh, hsa, hta⟩ := views_hold CS CT hsc0 hfs ha
    obtain ⟨hin, hrun, hhist, htin, hw, henv⟩ := ha
    have hsxe : sx1.val.toNat = Bs.insts.val.length := by
      have := mt hsh.2 hsxn; have := hin.le; omega
    have htxe : tx1.val.toNat = Bt.insts.val.length := by
      have := mt hth.2 htxn; have := htin.le; omega
    have hV := hview G (vg_extends_trans e8 hG) o s1.regs env hfsh (hsa hsxe)
    have hV' := hview' G hG o ts1.regs env hfsh (hta htxe)
    cases v with
    | VJmp sj =>
      cases w with
      | VJmp tj =>
        simp only at hsj3 htj2
        cases ok_inj' hsj3
        cases ok_inj' htj2
        rw [hsxe] at hin hrun
        exact ⟨s1, ts1, Or.inr ⟨hsj0, sc.val.toNat, n, s1, src_leave hin hhist hrun hV, le_refl _, hw.symm⟩,
          htin, Or.inr ⟨htj0, htxe, hV'⟩, fun m hm => hm⟩
      | _ => simp only at htj2; cases ok_inj' htj2; simp at htj0
    | _ => simp only at hsj3; cases ok_inj' hsj3; simp at hsj0

/-- The blocks a replay step enters: the target's (`absorb_ok`), then the source's
(`src_enter_scope_ok`, `bm_has`). -/
theorem tail_sim {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val)
    {vg9 vg12 : ValGraph} {sc tc sx4 tx3 sj4 tj3 tc2 tx5 sc2 sx6 : Std.I32}
    {tchain schain tchain2 schain2 : Pion.Array Std.I32} {Bs Bt : Block}
    (hsc0 : 0 ≤ sc.val) (htc0 : 0 ≤ tc.val) (hsx0 : 0 ≤ sx4.val) (htx0 : 0 ≤ tx3.val)
    (_hBs : src.blocks.val[sc.val.toNat]? = some Bs) (hBt : tgt.blocks.val[tc.val.toNat]? = some Bt)
    (hg9 : GPre cert vg9) (_hinfo_s : InfoOK src si) (_hinfo_t : InfoOK tgt ti)
    (hs1 : (if tj3 >= 0#i32 then do
        let t41 ← (if ((decide (tj3 <= 0#i32)) || (decide (tj3 >= ti.nb))) then ok true
          else do let x ← contains_int tchain tj3; ok x)
        let (t44, vg10) ← (if t41 then ok (true, vg9)
          else do let (t43, vg11) ← absorb_ok vg9 tgt cert.tvid tj3 tc; ok ((!t43), vg11))
        if t44 then ok (Sum.inl (11#i32, vg10)) else ok (Sum.inr (vg10, Pion.Array.push tchain tj3, tj3, 0#i32))
      else ok (Sum.inr (vg9, tchain, tc, tx3))) = ok (Sum.inr (vg12, tchain2, tc2, tx5)))
    (hs2 : (if sj4 >= 0#i32 then do
        let t46 ← (if ((decide (sj4 <= 0#i32)) || (decide (sj4 >= si.nb))) then ok true
          else do let x ← contains_int schain sj4; ok x)
        let t48 ← (if t46 then ok true else do let x ← blk_has_phi_leaf vg12 src cert.svid sj4; ok x)
        if t48 then ok (Sum.inl (13#i32, vg12)) else do
          let t49 ← src_enter_scope_ok vg12 tgt cert.tvid tc2 sj4
          let t51 ← (if (!t49) then ok true else do let x ← bm_has cert tc2 sj4; ok (!x))
          if t51 then ok (Sum.inl (14#i32, vg12)) else ok (Sum.inr (Pion.Array.push schain sj4, sj4, 0#i32))
      else ok (Sum.inr (schain, sc, sx4))) = ok (Sum.inr (schain2, sc2, sx6))) :
    vg_extends vg9 vg12 ∧ GPre cert vg12 ∧ (0 ≤ sc2.val ∧ 0 ≤ sx6.val ∧ 0 ≤ tc2.val ∧ 0 ≤ tx5.val) ∧
      (vg_extends vg12 G → ∀ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
        (env : SymEnv) (n N : Nat) (s0 ts1 : MState W) (tx1 : Nat),
        sc ∈ schain.val → (∀ x ∈ schain.val, 0 ≤ x.val) → n ≤ N → EnvOK o args env →
        SHist G src si cert.svid.val cert.facts.val cert.savail o env sc.val.toNat →
        MidState G src tgt cert si ti o args res env n sc.val.toNat tc.val.toNat Bs Bt s0 sx4.val.toNat
          tx3.val.toNat sj4 tj3 schain.val ts1 tx1 →
        ∃ env' n' s0' s' ts', RState G src tgt cert si ti o args res N sc2 sx6 tc2 tx5 schain2 env' n' s0' s' ts' ∧
          (TGoal tgt o args res tc2 tx5 ts' →
            ∃ m, restFrom o args tgt m tc.val.toNat Bt tx1 ts1 = some res)) := by
  -- the target part
  have htail : vg_extends vg9 vg12 ∧ GPre cert vg12 ∧ 0 ≤ tc2.val ∧ 0 ≤ tx5.val ∧
      (tj3.val < 0 → tc2 = tc ∧ tx5 = tx3 ∧ tchain2 = tchain) ∧
      (0 ≤ tj3.val → tc2 = tj3 ∧ tx5 = 0#i32 ∧ 0 < tj3.val ∧ tj3.val < ti.nb.val ∧
        absorb_ok vg9 tgt cert.tvid tj3 tc = ok (true, vg12)) := by
    by_cases hj : tj3 >= 0#i32
    · rw [ite_eq_left hj] at hs1
      obtain ⟨t41, ht41, h1⟩ := bind_eq_ok hs1
      obtain ⟨q44, hq44, h2⟩ := bind_eq_ok h1
      obtain ⟨t44, vg10⟩ := q44
      try simp only [uncurry_apply_pair] at h2
      cases t44 with
      | true => simp only [↓reduceIte] at h2; cases ok_inj' h2
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h2
      have e2 := ok_inj' h2
      simp only [Sum.inr.injEq, Prod.mk.injEq] at e2
      obtain ⟨eg, ec, et, ex⟩ := e2
      subst eg ec et ex
      cases t41 with
      | true => simp only [↓reduceIte] at hq44; cases ok_inj' hq44
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at hq44
      obtain ⟨q43, hq43, h3⟩ := bind_eq_ok hq44
      obtain ⟨t43, vg11⟩ := q43
      try simp only [uncurry_apply_pair] at h3
      have e3 := ok_inj' h3
      simp only [Prod.mk.injEq] at e3
      have ht43 : t43 = true := by revert e3; cases t43 <;> simp
      subst ht43
      have eg := e3.2
      subst eg
      obtain ⟨e10, d10, -⟩ := absorb_ok_sound hq43 rfl hg9.1 hg9.2.2.1
      have hj0 : 0 ≤ tj3.val := by simpa [i32_le_iff] using hj
      have hrange : 0 < tj3.val ∧ tj3.val < ti.nb.val := by
        by_contra hc
        rw [ite_eq_left (by
          simp only [Bool.or_eq_true, decide_eq_true_eq, i32_le_iff, ge_iff_le, i32_zero_val]
          omega)] at ht41
        cases ok_inj' ht41
      exact ⟨e10, gPre_ext e10 d10 hg9, hj0, by simp, fun h => by omega,
        fun _ => ⟨rfl, rfl, hrange.1, hrange.2, hq43⟩⟩
    · rw [ite_eq_right hj] at hs1
      have e1 := ok_inj' hs1
      simp only [Sum.inr.injEq, Prod.mk.injEq] at e1
      obtain ⟨eg, ec, et, ex⟩ := e1
      subst eg ec et ex
      have hj0 : tj3.val < 0 := by simpa [i32_le_iff] using hj
      exact ⟨vg_extends_refl _, hg9, htc0, htx0, fun _ => ⟨rfl, rfl, rfl⟩, fun h => by omega⟩
  obtain ⟨e12, hg12, htc2, htx5, htneg, htpos⟩ := htail
  -- the source part
  have hsrc : (sj4.val < 0 → sc2 = sc ∧ sx6 = sx4 ∧ schain2 = schain) ∧
      (0 ≤ sj4.val → sc2 = sj4 ∧ sx6 = 0#i32 ∧ schain2 = Pion.Array.push schain sj4 ∧
        0 < sj4.val ∧ sj4.val < si.nb.val ∧ contains_int schain sj4 = ok false ∧
        src_enter_scope_ok vg12 tgt cert.tvid tc2 sj4 = ok true ∧ bm_has cert tc2 sj4 = ok true) := by
    by_cases hj : sj4 >= 0#i32
    · rw [ite_eq_left hj] at hs2
      have hj0 : 0 ≤ sj4.val := by simpa [i32_le_iff] using hj
      refine ⟨fun h => by omega, fun _ => ?_⟩
      obtain ⟨t46, ht46, h1⟩ := bind_eq_ok hs2
      obtain ⟨t48, ht48, h2⟩ := bind_eq_ok h1
      cases t48 with
      | true => simp only [↓reduceIte] at h2; cases ok_inj' h2
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h2
      cases t46 with
      | true => simp only [↓reduceIte] at ht48; cases ok_inj' ht48
      | false =>
      obtain ⟨t49, ht49, h3⟩ := bind_eq_ok h2
      obtain ⟨t51, ht51, h4⟩ := bind_eq_ok h3
      cases t51 with
      | true => simp only [↓reduceIte] at h4; cases ok_inj' h4
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h4
      have e4 := ok_inj' h4
      simp only [Sum.inr.injEq, Prod.mk.injEq] at e4
      obtain ⟨es, ec, ex⟩ := e4
      subst es ec ex
      cases t49 with
      | false => simp only [Bool.not_false, ↓reduceIte] at ht51; cases ok_inj' ht51
      | true =>
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at ht51
      obtain ⟨t50, ht50, h5⟩ := bind_eq_ok ht51
      have ht50' : t50 = true := by have := ok_inj' h5; revert this; cases t50 <;> simp
      subst ht50'
      by_cases hr : ((decide (sj4 <= 0#i32)) || (decide (sj4 >= si.nb))) = true
      · rw [ite_eq_left hr] at ht46; cases ok_inj' ht46
      rw [ite_eq_right hr] at ht46
      have hrange : 0 < sj4.val ∧ sj4.val < si.nb.val := by
        simp only [Bool.or_eq_true, decide_eq_true_eq, i32_le_iff, ge_iff_le, i32_zero_val, not_or,
          not_le] at hr
        exact ⟨hr.1, hr.2⟩
      exact ⟨rfl, rfl, rfl, hrange.1, hrange.2, bind_id_ok ht46, ht49, ht50⟩
    · rw [ite_eq_right hj] at hs2
      have e1 := ok_inj' hs2
      simp only [Sum.inr.injEq, Prod.mk.injEq] at e1
      obtain ⟨es, ec, ex⟩ := e1
      subst es ec ex
      have hj0 : sj4.val < 0 := by simpa [i32_le_iff] using hj
      exact ⟨fun _ => ⟨rfl, rfl, rfl⟩, fun h => by omega⟩
  have hpos2 : 0 ≤ sc2.val ∧ 0 ≤ sx6.val := by
    by_cases hj : 0 ≤ sj4.val
    · obtain ⟨e1, e2, -⟩ := hsrc.2 hj; subst sc2 sx6; exact ⟨hj, by simp⟩
    · obtain ⟨e1, e2, -⟩ := hsrc.1 (by omega); subst sc2 sx6; exact ⟨hsc0, hsx0⟩
  refine ⟨e12, hg12, ⟨hpos2.1, hpos2.2, htc2, htx5⟩,
    fun hG W o args res env n N s0 ts1 tx1 hsc hpos hnN henv hhist hmid => ?_⟩
  obtain ⟨s2, ts2, hsmid, htin, htmid, hback⟩ := hmid
  -- the target enters its next block, if any
  have htgt : ∃ ts3 Bt2, tgt.blocks.val[tc2.val.toNat]? = some Bt2 ∧
      TIn G tgt ti cert.tvid.val cert.tavail env tc2.val.toNat Bt2 ts3 tx5.val.toNat schain.val ∧
      ts3.world = ts2.world ∧
      (∀ m, restFrom o args tgt m tc2.val.toNat Bt2 tx5.val.toNat ts3 = some res →
        ∃ m', restFrom o args tgt m' tc.val.toNat Bt tx3.val.toNat ts2 = some res) := by
    by_cases hj : 0 ≤ tj3.val
    · obtain ⟨e1, e2, -, -, habs⟩ := htpos hj
      subst tc2 tx5
      obtain ⟨htx3e, hedge⟩ : tx3.val.toNat = Bt.insts.val.length ∧ EdgeTaken o ts2.regs Bt.term tj3 := by
        rcases htmid with h | ⟨-, h1, h2⟩
        · omega
        · exact ⟨h1, h2⟩
      obtain ⟨-, -, B, hB, hphis⟩ := absorb_ok_sound habs rfl hg9.1 hg9.2.2.1
      have hin3 := htin
      rw [htx3e] at hin3
      obtain ⟨-, -, -, hsucc⟩ := CT.block _ Bt htin.reach htin.blk
      obtain ⟨-, -, -, S, hS, hsarms⟩ := hsucc tj3 (edgeTaken_mem hedge)
      rw [hB] at hS; cases hS
      have htcI : ((tc.val.toNat : Nat) : Int) = tc.val := by omega
      obtain ⟨R, hR, htin3⟩ := tgt_enter CT (env' := env) (schain' := schain.val) hin3 hedge hB
        (fun P hP => by
          obtain ⟨a, ha, v', hv', hd0, vv, hk, he⟩ := hphis P hP
          refine ⟨a, by rw [htcI]; exact ha, fun v hv hvv => ?_⟩
          rw [hv'] at hv; cases hv
          obtain ⟨a', ha', haAv⟩ := hsarms P hP
          rw [htcI, ha] at ha'
          have eaa := Option.some.inj ha'
          subst eaa
          dsimp only at vv hk he
          rw [atomVal_eq (atomKnown_extends hG hk) (agree_of_avail hin3.regs henv.1 haAv),
            atomSem_extends hG hk, ← he env, extends_evI hG env vv])
        (fun _ _ _ _ _ _ => rfl)
      refine ⟨_, B, hB, htin3, rfl, fun m hm => ⟨m + 1, ?_⟩⟩
      rw [htx3e]
      exact tgt_back_edge hj hedge hB hR hm
    · obtain ⟨e1, e2, -⟩ := htneg (by omega)
      subst tc2 tx5
      exact ⟨ts2, Bt, hBt, htin, rfl, fun m hm => ⟨m, hm⟩⟩
  obtain ⟨ts3, Bt2, hBt2, htin3, hw3, hback3⟩ := htgt
  have hgoal : TGoal tgt o args res tc2 tx5 ts3 → ∃ m, restFrom o args tgt m tc.val.toNat Bt tx1 ts1 = some res := by
    rintro ⟨Bt', m, hBt', hm⟩
    rw [hBt2] at hBt'; cases hBt'
    obtain ⟨m', hm'⟩ := hback3 m hm
    exact ⟨m', hback m' hm'⟩
  by_cases hj : 0 ≤ sj4.val
  · obtain ⟨e1, e2, e3, hj1, hj2, hcont, hscope, hbm⟩ := hsrc.2 hj
    subst sc2 sx6 schain2
    obtain ⟨-, prev, n', s', hab, hn', hw'⟩ : 0 ≤ sj4.val ∧ ∃ prev n' s',
        SrcAbout G src si cert.svid.val cert.facts.val cert.savail o args env prev sj4 n' s' res ∧
        n' ≤ n ∧ s'.world = ts2.world := by
      rcases hsmid with h | h
      · omega
      · exact h
    have hnot : sj4 ∉ schain.val := fun hm => by
      have := (contains_int_spec hcont).2 hm; cases this
    obtain ⟨B', hB', hsc'⟩ := src_enter_scope_ok_sound hscope
    rw [hBt2] at hB'; cases hB'
    obtain ⟨j, hj1', hj2'⟩ := bm_has_true hbm
    have htc2n : tc2 = i32n tc2.val.toNat := i32n_of_val htc2
    obtain ⟨n'', Bj, R, env', hn'', hBj, hin', hhist', hrun', htin', hag⟩ := pair_src_move CS CT hab htin3 hnot
      ⟨j, by rw [← htc2n]; exact hj1', hj2'⟩
      (fun P hP v hv hvv => by
        obtain ⟨v', hv', -, hmen⟩ := hsc' P hP
        rw [hv] at hv'; cases hv'
        have hv12 : Valid vg12 v := by
          rcases hg12.2.2.1 _ v hv with rfl | h'
          · exact absurd hvv.1 (by simp)
          · exact h'
        intro e e' ha
        rw [extends_evI hG e' hv12, extends_evI hG e hv12]
        exact vid_mentions_blk_sound hmen hv12.1 ha)
    refine ⟨env', n'', { regs := R, world := s'.world }, { regs := R, world := s'.world }, ts3, ⟨hj, by simp,
      htc2, htx5, by omega, by rw [push_val]; simp, ⟨by rw [hag.2.1]; exact henv.1,
        fun c k => by rw [hag.1]; exact henv.2 c k⟩, by rw [hw3, ← hw'],
      fun x hx => by rw [push_val] at hx; rcases List.mem_append.1 hx with h | h
                     · exact hpos x h
                     · simp at h; rw [h]; exact hj, Bj, Bt2, ?_⟩, hgoal⟩
    simp only [i32_zero_val, Int.toNat_zero]
    exact ⟨hin', hhist', hrun', tin_mono_chain htin' (fun x hx => by
      rw [push_val]; rcases List.mem_cons.1 hx with h | h
      · rw [h]; simp
      · exact List.mem_append_left _ h)⟩
  · obtain ⟨e1, e2, e3⟩ := hsrc.1 (by omega)
    subst sc2 sx6 schain2
    obtain ⟨-, hin2, hrun2, hw2⟩ : sj4.val < 0 ∧
        SIn G src si cert.svid.val cert.facts.val cert.savail o args env sc.val.toNat Bs s0 s2 sx4.val.toNat ∧
        restFrom o args src n sc.val.toNat Bs sx4.val.toNat s2 = some res ∧ ts2.world = s2.world := by
      rcases hsmid with h | h
      · exact h
      · omega
    exact ⟨env, n, s0, s2, ts3, ⟨hsc0, hsx0, htc2, htx5, hnN, hsc, henv, by rw [hw3, hw2], hpos, Bs, Bt2,
      hin2, hhist, hrun2, htin3⟩, hgoal⟩

/-- One iteration of the replay loop: the value graph grows, and from any state of the runs at the
start of the iteration there is one at its end, whose target completion gives the target's. -/
theorem body_sim {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val)
    {steps : Pion.Array Step} {i : Std.I32} {g : ValGraph} {sc sx tc tx : Std.I32}
    {tchain schain : Pion.Array Std.I32} {i' : Std.I32} {g' : ValGraph} {sc' sx' tc' tx' : Std.I32}
    {tchain' schain' : Pion.Array Std.I32}
    (hb : replay_pair_loop0.body steps src cert tgt ti si i g sc sx tc tx tchain schain =
      ok (.cont (i', g', sc', sx', tc', tx', tchain', schain')))
    (hpre : GPre cert g) (hpos : 0 ≤ sc.val ∧ 0 ≤ sx.val ∧ 0 ≤ tc.val ∧ 0 ≤ tx.val) :
    vg_extends g g' ∧ GPre cert g' ∧ (0 ≤ sc'.val ∧ 0 ≤ sx'.val ∧ 0 ≤ tc'.val ∧ 0 ≤ tx'.val) ∧
      (vg_extends g' G → ∀ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
        (N : Nat) (env : SymEnv) (n : Nat) (s0 s ts : MState W),
        RState G src tgt cert si ti o args res N sc sx tc tx schain env n s0 s ts →
        ∃ env' n' s0' s' ts', RState G src tgt cert si ti o args res N sc' sx' tc' tx' schain' env' n' s0' s' ts' ∧
          (TGoal tgt o args res tc' tx' ts' → TGoal tgt o args res tc tx ts)) := by
  unfold replay_pair_loop0.body at hb
  obtain ⟨nst, hnst, hb1⟩ := bind_eq_ok hb
  by_cases hilt : i < nst
  swap
  · rw [ite_eq_right hilt] at hb1; cases ok_inj' hb1
  rw [ite_eq_left hilt] at hb1
  obtain ⟨st, hst, hb2⟩ := bind_eq_ok hb1
  obtain ⟨sx1, hsx1, hb3⟩ := bind_eq_ok hb2
  obtain ⟨q4, hq4, hb4⟩ := bind_eq_ok hb3
  obtain ⟨tx1, vg1⟩ := q4
  try simp only [uncurry_apply_pair] at hb4
  obtain ⟨Bs, hBs, hb5⟩ := bind_eq_ok hb4
  obtain ⟨nsi, hnsi, hb6⟩ := bind_eq_ok hb5
  obtain ⟨Bt, hBt, hb7⟩ := bind_eq_ok hb6
  obtain ⟨nti, hnti, hb8⟩ := bind_eq_ok hb7
  obtain ⟨fs, hfs, hb9⟩ := bind_eq_ok hb8
  obtain ⟨sres, hsres, hb10⟩ := bind_eq_ok hb9
  cases sres with
  | inl e => simp only at hb10; cases ok_inj' hb10
  | inr q =>
  obtain ⟨vg9, sx4, tx3, sj4, tj3⟩ := q
  simp only at hb10
  obtain ⟨s1r, hs1r, hb11⟩ := bind_eq_ok hb10
  cases s1r with
  | inl e => simp only at hb11; cases ok_inj' hb11
  | inr q =>
  obtain ⟨vg12, tchain2, tc2, tx5⟩ := q
  simp only at hb11
  obtain ⟨s2r, hs2r, hb12⟩ := bind_eq_ok hb11
  cases s2r with
  | inl e => simp only at hb12; cases ok_inj' hb12
  | inr q =>
  obtain ⟨schain2, sc2, sx6⟩ := q
  simp only at hb12
  have e12 := ok_inj' hb12
  simp only [ControlFlow.cont.injEq, Prod.mk.injEq] at e12
  obtain ⟨-, eg, esc, esx, etc, etx, etch, esch⟩ := e12
  subst eg esc esx etc etx etch esch
  -- the skips
  obtain ⟨Bs', hBs', -, hsx01, hsxl1, hnw, heff⟩ := skip_src_pure_sound hsx1 hpos.2.1
  obtain ⟨e1, d1, Bt', hBt', -, htx01, htxl1, hpt⟩ := skip_tgt_pure_sound hq4 hpos.2.2.2 hpre.1 hpre.2.2.1
  dsimp only at e1 d1 htx01 htxl1 hpt
  obtain ⟨-, hBsl, hBsv⟩ := arr_get_ok hBs
  have hBsb : src.blocks.val[sc.val.toNat]? = some Bs := by rw [List.getElem?_eq_getElem hBsl, hBsv]
  rw [hBsb] at hBs'; cases hBs'
  obtain ⟨-, hBtl, hBtv⟩ := arr_get_ok hBt
  have hBtb : tgt.blocks.val[tc.val.toNat]? = some Bt := by rw [List.getElem?_eq_getElem hBtl, hBtv]
  rw [hBtb] at hBt'; cases hBt'
  have hg1 : GPre cert vg1 := gPre_ext e1 d1 hpre
  have hsx1p : 0 ≤ sx1.val := by omega
  have htx1p : 0 ≤ tx1.val := by omega
  -- the step's own action, then the blocks it enters
  obtain ⟨e9, hg9, hsx4, htx3, hact⟩ := action_sim CS CT st hpos.1 hpos.2.2.1 hsx1p htx1p hBs hBt hnsi hnti
    hfs hg1 e1 hpre.2.1 (fun hx => heff hx hsx1p) rfl hsres
  obtain ⟨e12, hg12, hposn, htl⟩ := tail_sim CS CT hpos.1 hpos.2.2.1 hsx4 htx3 hBsb hBtb hg9 CS.info CT.info
    hs1r hs2r
  refine ⟨vg_extends_trans e1 (vg_extends_trans e9 e12), hg12, hposn,
    fun hG W o args res N env n s0 s ts hrs => ?_⟩
  obtain ⟨hsc0, hsx0, htc0, htx0, hnN, hscm, henv, hw, hchain, Bs0, Bt0, hin, hhist, hrun, htin⟩ := hrs
  have eB : Bs = Bs0 := by have := hin.blk; rw [hBsb] at this; exact Option.some.inj this
  subst eB
  have eT : Bt = Bt0 := by have := htin.blk; rw [hBtb] at this; exact Option.some.inj this
  subst eT
  have hsxle := hin.le
  have htxle := htin.le
  have hsx1le : sx1.val.toNat ≤ Bs.insts.val.length := by
    have := hsxl1 (by omega); omega
  have htx1le : tx1.val.toNat ≤ Bt.insts.val.length := by
    have := htxl1 (by omega); omega
  obtain ⟨s1, hin1, hrun1, hws1⟩ := src_skip_run CS (sx1.val.toNat - sx.val.toNat) sx.val.toNat s hin hrun
    (by omega) (fun i hi h1 h2 => hnw i hi h1 (by omega))
  rw [show sx.val.toNat + (sx1.val.toNat - sx.val.toNat) = sx1.val.toNat by omega] at hin1 hrun1
  obtain ⟨ts1, htin1, hwt1, hback1⟩ := tgt_skip_run CT henv (res := res) (tx1.val.toNat - tx.val.toNat)
    tx.val.toNat ts htin (by omega)
    (fun i hi h1 h2 => pureTgt_extends (vg_extends_trans e9 (vg_extends_trans e12 hG)) (hpt i hi h1 (by omega)))
  rw [show tx.val.toNat + (tx1.val.toNat - tx.val.toNat) = tx1.val.toNat by omega] at htin1 hback1
  have hmid := hact (vg_extends_trans e12 hG) o args res env n s0 s1 ts1 schain.val hscm
    ⟨hin1, hrun1, hhist, htin1, by rw [hwt1, hws1, hw], henv⟩
  obtain ⟨env', n', s0', s', ts', hRS, hgoal⟩ := htl hG o args res env n N s0 ts1 tx1.val.toNat hscm hchain hnN
    henv hhist hmid
  refine ⟨env', n', s0', s', ts', hRS, fun hg => ?_⟩
  obtain ⟨m, hm⟩ := hgoal hg
  obtain ⟨m', hm'⟩ := hback1 ⟨m, hm⟩
  exact ⟨Bt, m', hBtb, hm'⟩

theorem body_done {steps : Pion.Array Step} {src tgt : Func} {cert : Cert} {si ti : FnInfo} {i : Std.I32}
    {g : ValGraph} {sc sx tc tx : Std.I32} {tchain schain : Pion.Array Std.I32}
    {y : Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 × Pion.Array Std.I32 × Pion.Array Std.I32}
    (hb : replay_pair_loop0.body steps src cert tgt ti si i g sc sx tc tx tchain schain = ok (.done (.inr y))) :
    y = (i, g, sc, sx, tc, tx, tchain, schain) := by
  unfold replay_pair_loop0.body at hb
  obtain ⟨nst, hnst, hb1⟩ := bind_eq_ok hb
  by_cases hilt : i < nst
  · rw [ite_eq_left hilt] at hb1
    obtain ⟨st, -, hb2⟩ := bind_eq_ok hb1
    obtain ⟨sx1, -, hb3⟩ := bind_eq_ok hb2
    obtain ⟨q4, -, hb4⟩ := bind_eq_ok hb3
    obtain ⟨tx1, vg1⟩ := q4
    try simp only [uncurry_apply_pair] at hb4
    obtain ⟨Bs, -, hb5⟩ := bind_eq_ok hb4
    obtain ⟨nsi, -, hb6⟩ := bind_eq_ok hb5
    obtain ⟨Bt, -, hb7⟩ := bind_eq_ok hb6
    obtain ⟨nti, -, hb8⟩ := bind_eq_ok hb7
    obtain ⟨fs, -, hb9⟩ := bind_eq_ok hb8
    obtain ⟨sres, -, hb10⟩ := bind_eq_ok hb9
    cases sres with
    | inl e => simp only at hb10; cases ok_inj' hb10
    | inr q =>
    obtain ⟨vg9, sx4, tx3, sj4, tj3⟩ := q
    simp only at hb10
    obtain ⟨s1r, -, hb11⟩ := bind_eq_ok hb10
    cases s1r with
    | inl e => simp only at hb11; cases ok_inj' hb11
    | inr q =>
    obtain ⟨vg12, tchain2, tc2, tx5⟩ := q
    simp only at hb11
    obtain ⟨s2r, -, hb12⟩ := bind_eq_ok hb11
    cases s2r with
    | inl e => simp only at hb12; cases ok_inj' hb12
    | inr q =>
    obtain ⟨schain2, sc2, sx6⟩ := q
    simp only at hb12
    cases ok_inj' hb12
  · rw [ite_eq_right hilt] at hb1
    have e := ok_inj' hb1
    simp only [ControlFlow.done.injEq, Sum.inr.injEq] at e
    exact e.symm

/-- What the replay loop gives, from one of its states to its end. -/
def LoopRel (G : ValGraph) (src tgt : Func) (cert : Cert) (si ti : FnInfo)
    (x : Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 × Pion.Array Std.I32 × Pion.Array Std.I32)
    (r : Sum (Std.I32 × ValGraph)
      (Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 × Pion.Array Std.I32 × Pion.Array Std.I32)) :
    Prop :=
  match x with
  | (_, g, sc, sx, tc, tx, _, schain) => GPre cert g → (0 ≤ sc.val ∧ 0 ≤ sx.val ∧ 0 ≤ tc.val ∧ 0 ≤ tx.val) →
    ∀ y, r = .inr y →
      match y with
      | (_, g', sc', sx', tc', tx', _, schain') =>
        vg_extends g g' ∧ GPre cert g' ∧ (0 ≤ sc'.val ∧ 0 ≤ sx'.val ∧ 0 ≤ tc'.val ∧ 0 ≤ tx'.val) ∧
        (vg_extends g' G → ∀ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (res : TermOutcome W)
          (N : Nat) (env : SymEnv) (n : Nat) (s0 s ts : MState W),
          RState G src tgt cert si ti o args res N sc sx tc tx schain env n s0 s ts →
          (∀ env' n' s0' s' ts', RState G src tgt cert si ti o args res N sc' sx' tc' tx' schain' env' n' s0' s' ts' →
            TGoal tgt o args res tc' tx' ts') →
          TGoal tgt o args res tc tx ts)

theorem loop_sim {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val) (steps : Pion.Array Step) :
    ∀ x r, loop (fun (x : Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 × Pion.Array Std.I32 ×
        Pion.Array Std.I32) =>
      match x with
      | (i, vg, sc, sx, tc, tx, tchain, schain) =>
        replay_pair_loop0.body steps src cert tgt ti si i vg sc sx tc tx tchain schain) x = ok r →
    LoopRel G src tgt cert si ti x r := by
  apply loop_ok_rel
  rintro ⟨i, g, sc, sx, tc, tx, tchain, schain⟩ c r hb hc
  intro hpre hpos y hy
  cases c with
  | cont x' =>
    obtain ⟨i', g', sc', sx', tc', tx', tchain', schain'⟩ := x'
    obtain ⟨e1, hg1, hpos1, hsem1⟩ := body_sim CS CT hb hpre hpos
    have hrel := hc hg1 hpos1 y hy
    obtain ⟨i2, g2, sc2, sx2, tc2, tx2, tchain2, schain2⟩ := y
    obtain ⟨e2, hg2, hpos2, hsem2⟩ := hrel
    refine ⟨vg_extends_trans e1 e2, hg2, hpos2, fun hG W o args res N env n s0 s ts hrs hfin => ?_⟩
    obtain ⟨env', n', s0', s', ts', hrs', hback⟩ := hsem1 (vg_extends_trans e2 hG) o args res N env n s0 s ts hrs
    exact hback (hsem2 hG o args res N env' n' s0' s' ts' hrs' hfin)
  | done d =>
    simp only at hc
    subst hc
    subst hy
    have hb' : replay_pair_loop0.body steps src cert tgt ti si i g sc sx tc tx tchain schain =
        ok (.done (.inr y)) := hb
    have hd := body_done hb'
    subst hd
    exact ⟨vg_extends_refl _, hpre, hpos, fun _ W o args res N env n s0 s ts hrs hfin =>
      hfin env n s0 s ts hrs⟩

/-- A failure code of a replay step: positive and below 100. -/
abbrev Code (k : Std.I32) : Prop := 0 < k.val ∧ k.val < 100

theorem step_inl {src tgt : Func} {cert : Cert} {vg1 : ValGraph} {sc tc sx1 tx1 nsi nti : Std.I32}
    {fs : Pion.Array Fact} (st : Step) {e : Std.I32 × ValGraph}
    (hst : (match (generalizing := false) st with
      | .MatchEff => do
        let (t20, vg2) ← do
          if ((!(decide (sx1 < nsi))) || (!(decide (tx1 < nti)))) then ok (true, vg1)
          else do
            let a ← Pion.Array.get src.blocks sc
            let b ← Pion.Array.get a.insts sx1
            let c ← Pion.Array.get tgt.blocks tc
            let d ← Pion.Array.get c.insts tx1
            let (t19, vg3) ← match_effect_c vg1 cert.svid cert.tvid fs b d
            ok ((!t19), vg3)
        if t20 then ok (.inl (3#i32, vg2))
        else ok (.inr (vg2, Pion.I32.add sx1 1#i32, Pion.I32.add tx1 1#i32, (-1)#i32, (-1)#i32))
      | .SkipSrcReadOnly => do
        let t24 ← do
          if (!(decide (sx1 < nsi))) then ok true
          else do
            let a ← Pion.Array.get src.blocks sc
            let b ← Pion.Array.get a.insts sx1
            let c ← src_skippable b
            ok (!c)
        if t24 then ok (.inl (4#i32, vg1))
        else ok (.inr (vg1, Pion.I32.add sx1 1#i32, tx1, (-1)#i32, (-1)#i32))
      | .SrcJmp =>
        if (decide (sx1 < nsi)) then ok (.inl (5#i32, vg1))
        else do
          let (v, vg4) ← src_view vg1 src cert.svid fs sc
          let sj1 ← view_jmp v
          ok (.inr (vg4, sx1, tx1, sj1, (-1)#i32))
      | .SrcJoin =>
        if (decide (sx1 < nsi)) then ok (.inl (6#i32, vg1))
        else do
          let (v, vg5) ← src_view vg1 src cert.svid fs sc
          match v with
          | .VJnz _ _ _ => do
            let sj2 ← src_join src sc
            ok (.inr (vg5, sx1, tx1, sj2, (-1)#i32))
          | _ => ok (.inl (7#i32, vg5))
      | .TgtJmp =>
        if (decide (tx1 < nti)) then ok (.inl (8#i32, vg1))
        else do
          let (v, vg6) ← tgt_view_c vg1 tgt cert.tvid fs tc
          let tj1 ← view_jmp v
          ok (.inr (vg6, sx1, tx1, (-1)#i32, tj1))
      | .BothJmp =>
        if ((decide (sx1 < nsi)) || (decide (tx1 < nti))) then ok (.inl (9#i32, vg1))
        else do
          let (v, vg7) ← src_view vg1 src cert.svid fs sc
          let sj3 ← view_jmp v
          let (w, vg8) ← tgt_view_c vg7 tgt cert.tvid fs tc
          let tj2 ← view_jmp w
          if ((decide (sj3 < 0#i32)) || (decide (tj2 < 0#i32))) then ok (.inl (10#i32, vg8))
          else ok (.inr (vg8, sx1, tx1, sj3, tj2))) = ok (Sum.inl e)) : Code e.1 := by
  have lit : ∀ (k : Std.I32) (g : ValGraph), Code k →
      (Sum.inl (k, g) : Sum (Std.I32 × ValGraph) (ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32)) = Sum.inl e →
      Code e.1 := by
    intro k g hk he; simp only [Sum.inl.injEq] at he; rw [← he]; exact hk
  cases st with
  | MatchEff =>
    simp only at hst
    obtain ⟨q, -, h1⟩ := bind_eq_ok hst
    obtain ⟨t, g⟩ := q
    try simp only [uncurry_apply_pair] at h1
    split at h1
    · exact lit _ _ (by decide) (ok_inj' h1)
    · cases ok_inj' h1
  | SkipSrcReadOnly =>
    simp only at hst
    obtain ⟨t, -, h1⟩ := bind_eq_ok hst
    split at h1
    · exact lit _ _ (by decide) (ok_inj' h1)
    · cases ok_inj' h1
  | SrcJmp =>
    simp only at hst
    split at hst
    · exact lit _ _ (by decide) (ok_inj' hst)
    · obtain ⟨q, -, h1⟩ := bind_eq_ok hst
      obtain ⟨v, g⟩ := q
      try simp only [uncurry_apply_pair] at h1
      obtain ⟨sj, -, h2⟩ := bind_eq_ok h1
      cases ok_inj' h2
  | SrcJoin =>
    simp only at hst
    split at hst
    · exact lit _ _ (by decide) (ok_inj' hst)
    · obtain ⟨q, -, h1⟩ := bind_eq_ok hst
      obtain ⟨v, g⟩ := q
      try simp only [uncurry_apply_pair] at h1
      cases v with
      | VJnz _ _ _ =>
        simp only at h1
        obtain ⟨sj, -, h2⟩ := bind_eq_ok h1
        cases ok_inj' h2
      | _ => simp only at h1; exact lit _ _ (by decide) (ok_inj' h1)
  | TgtJmp =>
    simp only at hst
    split at hst
    · exact lit _ _ (by decide) (ok_inj' hst)
    · obtain ⟨q, -, h1⟩ := bind_eq_ok hst
      obtain ⟨v, g⟩ := q
      try simp only [uncurry_apply_pair] at h1
      obtain ⟨tj, -, h2⟩ := bind_eq_ok h1
      cases ok_inj' h2
  | BothJmp =>
    simp only at hst
    split at hst
    · exact lit _ _ (by decide) (ok_inj' hst)
    · obtain ⟨q, -, h1⟩ := bind_eq_ok hst
      obtain ⟨v, g⟩ := q
      try simp only [uncurry_apply_pair] at h1
      obtain ⟨sj, -, h2⟩ := bind_eq_ok h1
      obtain ⟨q2, -, h3⟩ := bind_eq_ok h2
      obtain ⟨w, g2⟩ := q2
      try simp only [uncurry_apply_pair] at h3
      obtain ⟨tj, -, h4⟩ := bind_eq_ok h3
      split at h4
      · exact lit _ _ (by decide) (ok_inj' h4)
      · cases ok_inj' h4

theorem body_inl {steps : Pion.Array Step} {src tgt : Func} {cert : Cert} {si ti : FnInfo} {i : Std.I32}
    {g : ValGraph} {sc sx tc tx : Std.I32} {tchain schain : Pion.Array Std.I32} {e : Std.I32 × ValGraph}
    (hb : replay_pair_loop0.body steps src cert tgt ti si i g sc sx tc tx tchain schain = ok (.done (.inl e))) :
    Code e.1 := by
  unfold replay_pair_loop0.body at hb
  obtain ⟨nst, -, hb1⟩ := bind_eq_ok hb
  by_cases hilt : i < nst
  · rw [ite_eq_left hilt] at hb1
    obtain ⟨st, -, hb2⟩ := bind_eq_ok hb1
    obtain ⟨sx1, -, hb3⟩ := bind_eq_ok hb2
    obtain ⟨q4, -, hb4⟩ := bind_eq_ok hb3
    obtain ⟨tx1, vg1⟩ := q4
    try simp only [uncurry_apply_pair] at hb4
    obtain ⟨Bs, -, hb5⟩ := bind_eq_ok hb4
    obtain ⟨nsi, -, hb6⟩ := bind_eq_ok hb5
    obtain ⟨Bt, -, hb7⟩ := bind_eq_ok hb6
    obtain ⟨nti, -, hb8⟩ := bind_eq_ok hb7
    obtain ⟨fs, -, hb9⟩ := bind_eq_ok hb8
    obtain ⟨sres, hsres, hb10⟩ := bind_eq_ok hb9
    cases sres with
    | inl e' =>
      simp only at hb10
      have := ok_inj' hb10
      simp only [ControlFlow.done.injEq, Sum.inl.injEq] at this
      subst this
      exact step_inl st hsres
    | inr q =>
    obtain ⟨vg9, sx4, tx3, sj4, tj3⟩ := q
    simp only at hb10
    obtain ⟨s1r, hs1r, hb11⟩ := bind_eq_ok hb10
    cases s1r with
    | inl e' =>
      simp only at hb11
      have := ok_inj' hb11
      simp only [ControlFlow.done.injEq, Sum.inl.injEq] at this
      subst this
      split at hs1r
      · obtain ⟨t41, -, h1⟩ := bind_eq_ok hs1r
        obtain ⟨q, -, h2⟩ := bind_eq_ok h1
        obtain ⟨t44, g10⟩ := q
        try simp only [uncurry_apply_pair] at h2
        split at h2
        · have := ok_inj' h2; simp only [Sum.inl.injEq] at this; rw [← this]; dsimp only; decide
        · cases ok_inj' h2
      · cases ok_inj' hs1r
    | inr q =>
    obtain ⟨vg12, tchain2, tc2, tx5⟩ := q
    simp only at hb11
    obtain ⟨s2r, hs2r, hb12⟩ := bind_eq_ok hb11
    cases s2r with
    | inl e' =>
      simp only at hb12
      have := ok_inj' hb12
      simp only [ControlFlow.done.injEq, Sum.inl.injEq] at this
      subst this
      split at hs2r
      · obtain ⟨t46, -, h1⟩ := bind_eq_ok hs2r
        obtain ⟨t48, -, h2⟩ := bind_eq_ok h1
        split at h2
        · have := ok_inj' h2; simp only [Sum.inl.injEq] at this; rw [← this]; dsimp only; decide
        · obtain ⟨t49, -, h3⟩ := bind_eq_ok h2
          obtain ⟨t51, -, h4⟩ := bind_eq_ok h3
          split at h4
          · have := ok_inj' h4; simp only [Sum.inl.injEq] at this; rw [← this]; dsimp only; decide
          · cases ok_inj' h4
      · cases ok_inj' hs2r
    | inr q =>
    obtain ⟨schain2, sc2, sx6⟩ := q
    simp only at hb12
    cases ok_inj' hb12
  · rw [ite_eq_right hilt] at hb1
    cases ok_inj' hb1

theorem loop_inl {steps : Pion.Array Step} {src tgt : Func} {cert : Cert} {si ti : FnInfo} :
    ∀ x e, loop (fun (x : Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 × Pion.Array Std.I32 ×
        Pion.Array Std.I32) =>
      match x with
      | (i, vg, sc, sx, tc, tx, tchain, schain) =>
        replay_pair_loop0.body steps src cert tgt ti si i vg sc sx tc tx tchain schain) x = ok (.inl e) →
    Code e.1 := by
  intro x e h
  have key := loop_ok_inv _ (fun _ => True)
    (fun (r : Sum (Std.I32 × ValGraph) (Std.I32 × ValGraph × Std.I32 × Std.I32 × Std.I32 × Std.I32 ×
      Pion.Array Std.I32 × Pion.Array Std.I32)) => ∀ e, r = .inl e → Code e.1)
    (by
      rintro ⟨i, g, sc, sx, tc, tx, tchain, schain⟩ c - hc
      cases c with
      | cont _ => trivial
      | done d =>
        intro e he
        subst he
        exact body_inl hc) x _ h trivial
  exact key e rfl

/-! ## A certified pair, then all of them -/

theorem head_ok_graph {vg : ValGraph} {src : Func} {svid : Pion.Array Std.I32} {tgt : Func}
    {tvid : Pion.Array Std.I32} {sb tb : Std.I32} {q : Bool × ValGraph}
    (h : head_ok vg src svid tgt tvid sb tb = ok q) : q.2 = vg := by
  unfold head_ok at h
  obtain ⟨B, -, h1⟩ := bind_eq_ok h
  obtain ⟨np, -, h2⟩ := bind_eq_ok h1
  obtain ⟨s, hs, h3⟩ := bind_eq_ok h2
  unfold head_ok_loop0 at hs
  have key := loop_ok_inv (fun j => head_ok_loop0.body np tgt tb tvid vg svid src sb j) (fun _ => True)
    (fun (r : Sum (Bool × ValGraph) Std.I32) => ∀ e, r = .inl e → e.2 = vg)
    (by
      intro j c _ hc
      unfold head_ok_loop0.body at hc
      split at hc
      · obtain ⟨B2, -, hc⟩ := bind_eq_ok hc
        obtain ⟨P, -, hc⟩ := bind_eq_ok hc
        obtain ⟨B3, -, hc⟩ := bind_eq_ok hc
        obtain ⟨P3, -, hc⟩ := bind_eq_ok hc
        obtain ⟨v, -, hc⟩ := bind_eq_ok hc
        obtain ⟨t7, -, hc⟩ := bind_eq_ok hc
        split at hc
        · rw [← ok_inj' hc]; intro e he; simp only [Sum.inl.injEq] at he; rw [← he]
        · obtain ⟨n8, -, hc⟩ := bind_eq_ok hc
          obtain ⟨k, -, hc⟩ := bind_eq_ok hc
          obtain ⟨t13, -, hc⟩ := bind_eq_ok hc
          obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
          cases sres with
          | inl r =>
            simp only at hc
            rw [← ok_inj' hc]
            intro e he
            simp only [Sum.inl.injEq] at he
            subst he
            split at hsres
            · obtain ⟨Bs, -, hsres⟩ := bind_eq_ok hsres
              obtain ⟨SP, -, hsres⟩ := bind_eq_ok hsres
              obtain ⟨t17, -, hsres⟩ := bind_eq_ok hsres
              split at hsres
              · have := ok_inj' hsres; simp only [Sum.inl.injEq] at this; rw [← this]
              · cases ok_inj' hsres
            · obtain ⟨t18, -, hsres⟩ := bind_eq_ok hsres
              split at hsres
              · have := ok_inj' hsres; simp only [Sum.inl.injEq] at this; rw [← this]
              · obtain ⟨node, -, hsres⟩ := bind_eq_ok hsres
                cases node <;> simp only at hsres <;> first
                  | (have := ok_inj' hsres; simp only [Sum.inl.injEq] at this; rw [← this])
                  | cases ok_inj' hsres
          | inr u => simp only at hc; rw [← ok_inj' hc]; trivial
      · rw [← ok_inj' hc]; intro e he; cases he)
    _ _ hs trivial
  cases s with
  | inl r => simp only at h3; rw [← ok_inj' h3]; exact key r rfl
  | inr j => simp only at h3; rw [← ok_inj' h3]

/-- `replay_pair` returning 0: the checks at the pair's entry, the replay loop, and the
terminator check at its end. -/
theorem replay_pair_dec {g : ValGraph} {src : Func} {si : FnInfo} {tgt : Func} {ti : FnInfo} {cert : Cert}
    {p : PairCert} {g' : ValGraph} (h : replay_pair g src si tgt ti cert p = ok (0#i32, g')) :
    0 ≤ p.sb.val ∧ p.sb.val < si.nb.val ∧ 0 ≤ p.tb.val ∧ p.tb.val < ti.nb.val ∧
      (∃ g1, head_ok g src cert.svid tgt cert.tvid p.sb p.tb = ok (true, g1)) ∧ bm_has cert p.tb p.sb = ok true ∧
      ∃ i1 vg2 sc1 sx1 tc1 tx1 tchain1 schain1,
        replay_pair_loop0 p.steps src cert tgt ti si 0#i32 g p.sb 0#i32 p.tb 0#i32 (Pion.Array.ofList [p.tb])
          (Pion.Array.ofList [p.sb]) = ok (.inr (i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1)) ∧
        ∃ sx2 tx2 vg3 Bs Bt nsi nti fs, skip_src_pure vg2 src cert.svid sc1 sx1 = ok sx2 ∧
          skip_tgt_pure vg2 tgt cert.tvid tc1 tx1 = ok (tx2, vg3) ∧ Pion.Array.get src.blocks sc1 = ok Bs ∧
          Pion.Array.length Bs.insts = ok nsi ∧ ¬ sx2 < nsi ∧ Pion.Array.get tgt.blocks tc1 = ok Bt ∧
          Pion.Array.length Bt.insts = ok nti ∧ ¬ tx2 < nti ∧ facts_of cert.facts sc1 = ok fs ∧
          check_end vg3 src tgt cert fs sc1 tc1 p.fin = ok (true, g') := by
  unfold replay_pair at h
  dsimp only at h
  split at h
  · cases ok_inj' h
  rename_i hr
  simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, not_lt, i32_le_iff, i32_lt_iff, ge_iff_le] at hr
  obtain ⟨⟨⟨h1, h2⟩, h3⟩, h4⟩ := hr
  obtain ⟨q1, hq1, h5⟩ := bind_eq_ok h
  obtain ⟨t1, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h5
  have hvg1 : vg1 = g := head_ok_graph hq1
  subst hvg1
  obtain ⟨t3, ht3, h6⟩ := bind_eq_ok h5
  split at h6
  · cases ok_inj' h6
  rename_i h3f
  have ht1 : t1 = true ∧ bm_has cert p.tb p.sb = ok true := by
    cases t1 with
    | false => simp only [Bool.not_false, ↓reduceIte] at ht3; cases ok_inj' ht3; exact absurd rfl h3f
    | true =>
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at ht3
      obtain ⟨t2, ht2, ht3'⟩ := bind_eq_ok ht3
      have := ok_inj' ht3'
      subst this
      refine ⟨rfl, ?_⟩
      cases t2 with
      | true => exact ht2
      | false => exact absurd rfl h3f
  obtain ⟨rfl, hbm⟩ := ht1
  obtain ⟨s, hs, h7⟩ := bind_eq_ok h6
  cases s with
  | inl e =>
    simp only at h7
    have := loop_inl _ e hs
    rw [ok_inj' h7] at this
    exact absurd this (by simp)
  | inr y =>
    obtain ⟨i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1⟩ := y
    simp only at h7
    obtain ⟨sx2, hsx2, h8⟩ := bind_eq_ok h7
    obtain ⟨q9, hq9, h9⟩ := bind_eq_ok h8
    obtain ⟨tx2, vg3⟩ := q9
    try simp only [uncurry_apply_pair] at h9
    obtain ⟨Bs, hBs, h10⟩ := bind_eq_ok h9
    obtain ⟨nsi, hnsi, h11⟩ := bind_eq_ok h10
    obtain ⟨t59, ht59, h12⟩ := bind_eq_ok h11
    split at h12
    · cases ok_inj' h12
    rename_i h59
    have hsx : ¬ sx2 < nsi ∧ ∃ Bt nti, Pion.Array.get tgt.blocks tc1 = ok Bt ∧ Pion.Array.length Bt.insts = ok nti ∧
        ¬ tx2 < nti := by
      split at ht59
      · cases ok_inj' ht59; exact absurd rfl h59
      · rename_i hlt
        obtain ⟨Bt, hBt, ht59⟩ := bind_eq_ok ht59
        obtain ⟨nti, hnti, ht59⟩ := bind_eq_ok ht59
        refine ⟨hlt, Bt, nti, hBt, hnti, fun hc => h59 ?_⟩
        rw [← ok_inj' ht59]; simpa using hc
    obtain ⟨hsxn, Bt, nti, hBt, hnti, htxn⟩ := hsx
    obtain ⟨fs, hfs, h13⟩ := bind_eq_ok h12
    obtain ⟨q14, hq14, h14⟩ := bind_eq_ok h13
    obtain ⟨t62, vg4⟩ := q14
    try simp only [uncurry_apply_pair] at h14
    have e14 := ok_inj' h14
    simp only [Prod.mk.injEq] at e14
    obtain ⟨et62, eg4⟩ := e14
    have ht62 : t62 = true := by revert et62; cases t62 <;> simp
    subst ht62 eg4
    exact ⟨h1, not_le.mp h2, h3, not_le.mp h4, ⟨_, hq1⟩, hbm, i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1, hs,
      sx2, tx2, vg3, Bs, Bt, nsi, nti, fs, hsx2, hq9, hBs, hnsi, hsxn, hBt, hnti, htxn, hfs, hq14⟩

theorem ofList_val {α : Type} (l : List α) : (Pion.Array.ofList l : Pion.Array α).val = l := rfl

/-- Every replayed pair: graphs of the replays all inside the final graph `G`. -/
def PairsOK (G : ValGraph) (src tgt : Func) (cert : Cert) (si ti : FnInfo) : Prop :=
  ∀ (i : Nat) p, cert.pairs.val[i]? = some p → ∃ g g', GPre cert g ∧ vg_extends g G ∧ vg_extends g' G ∧
    replay_pair g src si tgt ti cert p = ok (0#i32, g')

/-- From the start of a certified pair, the target ends as the source does. -/
theorem pair_sim {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val)
    (hpairs : PairsOK G src tgt cert si ti) {W : Type} (o : WorldOracle W) (args : List (BitVec 64))
    (res : TermOutcome W) :
    ∀ (N : Nat) (i : Nat) (p : PairCert) (env : SymEnv) (s0 ts : MState W) (Bs Bt : Block),
      cert.pairs.val[i]? = some p → 0 ≤ p.sb.val → 0 ≤ p.tb.val →
      SIn G src si cert.svid.val cert.facts.val cert.savail o args env p.sb.val.toNat Bs s0 s0 0 →
      SHist G src si cert.svid.val cert.facts.val cert.savail o env p.sb.val.toNat →
      restFrom o args src N p.sb.val.toNat Bs 0 s0 = some res →
      TIn G tgt ti cert.tvid.val cert.tavail env p.tb.val.toNat Bt ts 0 [p.sb] → ts.world = s0.world →
      EnvOK o args env →
      ∃ m, restFrom o args tgt m p.tb.val.toNat Bt 0 ts = some res := by
  intro N
  induction N using Nat.strong_induction_on with
  | _ N ih =>
  intro i p env s0 ts Bs Bt hp hsb0 htb0 hin hhist hrun htin hw henv
  obtain ⟨g, g', hg, hgG, hg'G, hrp⟩ := hpairs i p hp
  obtain ⟨-, -, -, -, -, -, i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1, hloop, sx2, tx2, vg3, Bs1, Bt1, nsi,
    nti, fs, hsx2, hq9, hBs1, hnsi, hsxn, hBt1, hnti, htxn, hfs, hce⟩ := replay_pair_dec hrp
  have hrel := loop_sim CS CT p.steps _ _ hloop hg ⟨hsb0, by simp, htb0, by simp⟩ _ rfl
  obtain ⟨e2, hg2, ⟨hsc1, hsx1, htc1, htx1⟩, hsem⟩ := hrel
  -- the final skips and the terminator check
  obtain ⟨Bs', hBs', -, hsx12, hsxl, hnw, -⟩ := skip_src_pure_sound hsx2 hsx1
  obtain ⟨e3, d3, Bt', hBt', -, htx12, htxl, hpt⟩ := skip_tgt_pure_sound hq9 htx1 hg2.1 hg2.2.2.1
  dsimp only at e3 d3 htx12 htxl hpt
  have hg3 : GPre cert vg3 := gPre_ext e3 d3 hg2
  obtain ⟨e4, d4, Bs'', Bt'', hBs'', -, hBt'', -, hend⟩ :=
    check_end_sound hce rfl hg3.1 hg3.2.1 hg3.2.2.1 hg3.2.2.2
  dsimp only at e4 d4 hend
  obtain ⟨-, hBs1l, hBs1v⟩ := arr_get_ok hBs1
  have hBs1b : src.blocks.val[sc1.val.toNat]? = some Bs1 := by rw [List.getElem?_eq_getElem hBs1l, hBs1v]
  rw [hBs1b] at hBs' hBs''; cases hBs'; cases hBs''
  obtain ⟨-, hBt1l, hBt1v⟩ := arr_get_ok hBt1
  have hBt1b : tgt.blocks.val[tc1.val.toNat]? = some Bt1 := by rw [List.getElem?_eq_getElem hBt1l, hBt1v]
  rw [hBt1b] at hBt' hBt''; cases hBt'; cases hBt''
  obtain ⟨hnsi1, -⟩ := arr_length_ok hnsi
  obtain ⟨hnti1, -⟩ := arr_length_ok hnti
  have hG3 : vg_extends vg3 G := vg_extends_trans e4 hg'G
  have hgoal := hsem (vg_extends_trans e3 hG3) o args res N env N s0 s0 ts
    ⟨hsb0, by simp, htb0, by simp, le_refl N, by simp, henv, hw,
      fun x hx => by simp at hx; rw [hx]; exact hsb0, Bs, Bt,
      by simpa using hin, hhist, by simpa using hrun, by simpa [ofList_val] using htin⟩
    (fun env' n' s0' s' ts' hrs => ?_)
  · obtain ⟨Bt0, m, hBt0, hm⟩ := hgoal
    rw [htin.blk] at hBt0; cases hBt0
    exact ⟨m, by simpa using hm⟩
  -- the end of the pair
  obtain ⟨-, -, -, -, hnN, hscm, henv', hw', -, Bs0, Bt0, hin0, hhist0, hrun0, htin0⟩ := hrs
  have eB : Bs1 = Bs0 := by have := hin0.blk; rw [hBs1b] at this; exact Option.some.inj this
  subst eB
  have eT : Bt1 = Bt0 := by have := htin0.blk; rw [hBt1b] at this; exact Option.some.inj this
  subst eT
  have hsxle := hin0.le
  have htxle := htin0.le
  have hsx2e : sx2.val.toNat = Bs1.insts.val.length := by
    have := hsxl (by omega)
    simp only [i32_lt_iff, hnsi1, not_lt] at hsxn
    omega
  have htx2e : tx2.val.toNat = Bt1.insts.val.length := by
    have := htxl (by omega)
    simp only [i32_lt_iff, hnti1, not_lt] at htxn
    omega
  obtain ⟨s2, hin2, hrun2, hws2⟩ := src_skip_run CS (sx2.val.toNat - sx1.val.toNat) sx1.val.toNat s' hin0 hrun0
    (by omega) (fun j hj h1 h2 => hnw j hj h1 (by omega))
  rw [show sx1.val.toNat + (sx2.val.toNat - sx1.val.toNat) = Bs1.insts.val.length by omega] at hin2 hrun2
  obtain ⟨ts2, htin2, hwt2, hback2⟩ := tgt_skip_run CT henv' (res := res) (tx2.val.toNat - tx1.val.toNat)
    tx1.val.toNat ts' htin0 (by omega)
    (fun j hj h1 h2 => pureTgt_extends hG3 (hpt j hj h1 (by omega)))
  rw [show tx1.val.toNat + (tx2.val.toNat - tx1.val.toNat) = Bt1.insts.val.length by omega] at htin2 hback2
  have hw2 : ts2.world = s2.world := by rw [hwt2, hws2, hw']
  have hfsh : FactsHold G env' fs.val := factsHold_of_facts_of hfs hin2.facts hsc1
  obtain ⟨-, -, hsterm, -⟩ := CS.block _ Bs1 hin2.reach hin2.blk
  obtain ⟨-, -, htterm, -⟩ := CT.block _ Bt1 htin2.reach htin2.blk
  have hEnd := hend G hg'G o env' s2.regs ts2.regs hfsh (termAgree_of_avail hin2.regs henv'.1 hsterm)
    (termAgree_of_avail htin2.regs henv'.1 htterm)
  rw [restFrom_end] at hrun2
  have tback : ∀ m, restFrom o args tgt m tc1.val.toNat Bt1 Bt1.insts.val.length ts2 = some res →
      TGoal tgt o args res tc1 tx1 ts' := fun m hm => by
    obtain ⟨m', hm'⟩ := hback2 ⟨m, hm⟩
    exact ⟨Bt1, m', hBt1b, hm'⟩
  rcases hEnd with ⟨h, c, a, c', a', hsT, htT, hval⟩ | ⟨hsT, htT⟩ | ⟨⟨sj, hsj⟩, hjump⟩
  · -- return
    refine tback 0 ?_
    rw [restFrom_end]
    rw [hsT] at hrun2
    unfold termCont at hrun2 ⊢
    rw [htT]
    rw [← hrun2]
    cases h with
    | false => simp only [Bool.false_eq_true, ↓reduceIte]; rw [hw2]
    | true =>
      obtain ⟨rfl, hv⟩ := hval rfl
      simp only [↓reduceIte]; rw [hv, hw2]
  · -- halt
    refine tback 0 ?_
    rw [restFrom_end]
    rw [hsT] at hrun2
    unfold termCont at hrun2 ⊢
    rw [htT, ← hrun2, hw2]
  · -- to the next pair
    obtain ⟨tj, k, g1, g1', htj, hnext, hg31, hd1, hg1'⟩ := hjump sj hsj
    obtain ⟨p', hk0, hp', hpsb, hptb, hedge⟩ := next_ok_true hnext rfl
    obtain ⟨gi, gi', hgi, hgiG, -, hrpi⟩ := hpairs k.val.toNat p' hp'
    obtain ⟨-, -, -, -, ⟨gh, hhead⟩, hbm, -⟩ := replay_pair_dec hrpi
    rw [hpsb, hptb] at hhead hbm
    have hgh : gh = gi := head_ok_graph hhead
    subst hgh
    have hab := src_leave hin2 hhist0 (by rw [restFrom_end]; exact hrun2) hsj
    have hg1p : GPre cert g1 := gPre_ext hg31 hd1 hg3
    obtain ⟨j, hj1, hj2⟩ := bm_has_true hbm
    have hsc1n : sc1 = i32n sc1.val.toNat := i32n_of_val hsc1
    have htc1n : tc1 = i32n tc1.val.toNat := i32n_of_val htc1
    rw [hsc1n, htc1n] at hedge
    obtain ⟨n'', Bj, R, env'', Btj, R', hn'', hBj, hinj, hhistj, hrunj, hBtj, hRj, htinj, htj0⟩ :=
      pair_enter CS CT hab htin2 htj hw2 hedge hg1p.1 (vg_extends_trans hg1' hg'G) hg1p.2.1 hg1p.2.2.1
        hg1p.2.2.2 hhead hgiG hgi.2.1 hgi.2.2.1 ⟨j, hj1, hj2⟩
    have hsj0 : 0 ≤ sj.val := hab.2.2.2.1
    obtain ⟨m, hm⟩ := ih n'' (by omega) k.val.toNat p' env'' { regs := R, world := s2.world }
      { ts2 with regs := R' } Bj Btj hp' (by rw [hpsb]; exact hsj0) (by rw [hptb]; exact htj0)
      (by rw [hpsb]; exact hinj) (by rw [hpsb]; exact hhistj) (by rw [hpsb]; exact hrunj)
      (by rw [hptb, hpsb]; exact htinj) (by simp [hw2]) ⟨hinj.sym, hinj.par⟩
    rw [hptb] at hm
    exact tback (m + 1) (tgt_back_edge htj0 htj hBtj hRj hm)

/-! ## From a valid certificate to the main theorem -/

/-- The codes `replay_pair` returns: `0` or a failure code. -/
theorem replay_code {g : ValGraph} {src : Func} {si : FnInfo} {tgt : Func} {ti : FnInfo} {cert : Cert}
    {p : PairCert} {q : Std.I32 × ValGraph} (h : replay_pair g src si tgt ti cert p = ok q) :
    q.1 = 0#i32 ∨ Code q.1 := by
  unfold replay_pair at h
  dsimp only at h
  split at h
  · rw [← ok_inj' h]; right; dsimp only; decide
  obtain ⟨q1, -, h5⟩ := bind_eq_ok h
  obtain ⟨t1, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h5
  obtain ⟨t3, -, h6⟩ := bind_eq_ok h5
  split at h6
  · rw [← ok_inj' h6]; right; dsimp only; decide
  obtain ⟨s, hs, h7⟩ := bind_eq_ok h6
  cases s with
  | inl e => simp only at h7; rw [← ok_inj' h7]; right; exact loop_inl _ e hs
  | inr y =>
    obtain ⟨i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1⟩ := y
    simp only at h7
    obtain ⟨sx2, -, h8⟩ := bind_eq_ok h7
    obtain ⟨q9, -, h9⟩ := bind_eq_ok h8
    obtain ⟨tx2, vg3⟩ := q9
    try simp only [uncurry_apply_pair] at h9
    obtain ⟨Bs, -, h10⟩ := bind_eq_ok h9
    obtain ⟨nsi, -, h11⟩ := bind_eq_ok h10
    obtain ⟨t59, -, h12⟩ := bind_eq_ok h11
    split at h12
    · rw [← ok_inj' h12]; right; dsimp only; decide
    obtain ⟨fs, -, h13⟩ := bind_eq_ok h12
    obtain ⟨q14, -, h14⟩ := bind_eq_ok h13
    obtain ⟨t62, vg4⟩ := q14
    try simp only [uncurry_apply_pair] at h14
    rw [← ok_inj' h14]
    cases t62
    · right; simp only [Bool.false_eq_true, ↓reduceIte]; decide
    · left; simp

/-- A replayed pair only grows the graph. -/
theorem replay_ext {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val) {g g' : ValGraph}
    {p : PairCert} (h : replay_pair g src si tgt ti cert p = ok (0#i32, g')) (hg : GPre cert g) :
    vg_extends g g' ∧ GPre cert g' := by
  obtain ⟨hsb0, -, htb0, -, -, -, i1, vg2, sc1, sx1, tc1, tx1, tchain1, schain1, hloop, sx2, tx2, vg3, Bs1, Bt1,
    nsi, nti, fs, hsx2, hq9, hBs1, hnsi, hsxn, hBt1, hnti, htxn, hfs, hce⟩ := replay_pair_dec h
  obtain ⟨e2, hg2, ⟨hsc1, hsx1, htc1, htx1⟩, -⟩ :=
    loop_sim CS CT p.steps _ _ hloop hg ⟨hsb0, by simp, htb0, by simp⟩ _ rfl
  obtain ⟨e3, d3, -⟩ := skip_tgt_pure_sound hq9 htx1 hg2.1 hg2.2.2.1
  dsimp only at e3 d3
  have hg3 : GPre cert vg3 := gPre_ext e3 d3 hg2
  obtain ⟨e4, d4, -⟩ := check_end_sound hce rfl hg3.1 hg3.2.1 hg3.2.2.1 hg3.2.2.2
  dsimp only at e4 d4
  exact ⟨vg_extends_trans e2 (vg_extends_trans e3 e4), gPre_ext e4 d4 hg3⟩

/-- The loop over the pairs of `cert_fail_code`. -/
theorem pairs_loop {G : ValGraph} {src tgt : Func} {cert : Cert} {si ti : FnInfo}
    (CS : SrcCtx G src si cert.svid.val cert.facts.val cert.savail)
    (CT : TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val) :
    ∀ x r, loop (fun (x : Std.I32 × ValGraph) => match x with
      | (i, vg) => cert_fail_code_loop0.body cert.pairs src si tgt ti cert i vg) x = ok r →
    match x with
    | (i, g) => 0 ≤ i.val → GPre cert g → (∀ c, r = .inl c → c ≠ 0#i32) ∧
      ∀ j g4, r = .inr (j, g4) → vg_extends g g4 ∧ GPre cert g4 ∧
        ∀ (k : Nat) p, i.val.toNat ≤ k → cert.pairs.val[k]? = some p →
          ∃ g g', GPre cert g ∧ vg_extends g g4 ∧ vg_extends g' g4 ∧
            replay_pair g src si tgt ti cert p = ok (0#i32, g') := by
  apply loop_ok_rel
  rintro ⟨i, g⟩ c r hb hc
  intro hi0 hg
  change cert_fail_code_loop0.body cert.pairs src si tgt ti cert i g = ok c at hb
  unfold cert_fail_code_loop0.body at hb
  obtain ⟨n, hn, hb⟩ := bind_eq_ok hb
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  split at hb
  · rename_i hlt
    simp only [i32_lt_iff] at hlt
    obtain ⟨p, hp, hb⟩ := bind_eq_ok hb
    obtain ⟨q, hq, hb⟩ := bind_eq_ok hb
    obtain ⟨rr, g1⟩ := q
    try simp only [uncurry_apply_pair] at hb
    have hcode := replay_code hq
    simp only at hcode
    split at hb
    · rename_i hne
      have e := ok_inj' hb
      subst e
      simp only at hc
      subst hc
      refine ⟨fun c hc' => ?_, fun j g4 hr => by cases hr⟩
      simp only [Sum.inl.injEq] at hc'
      subst hc'
      have hC : Code rr := hcode.resolve_left hne
      have h100 : (100#i32 : Std.I32).val = 100 := by decide
      intro h0
      have := congrArg (fun x : Std.I32 => x.val) h0
      rw [i32_add_val _ _ (by rw [h100]; have := hC.1; omega) (by rw [h100]; have := hC.2; omega), h100,
        i32_zero_val] at this
      have := hC.1
      omega
    · rename_i hz
      have e := ok_inj' hb
      subst e
      simp only at hc
      have hrr : rr = 0#i32 := not_not.mp hz
      subst hrr
      obtain ⟨-, hpl, hpv⟩ := arr_get_ok hp
      have hs := i32_toNat_succ (x := i) (n := cert.pairs.val.length) (by omega) hn2 hi0
      obtain ⟨e1, hg1⟩ := replay_ext CS CT hq hg
      obtain ⟨hinl, hinr⟩ := hc (by rw [hs.1]; omega) hg1
      refine ⟨hinl, fun j g4 hr => ?_⟩
      obtain ⟨e2, hg4, hk⟩ := hinr j g4 hr
      refine ⟨vg_extends_trans e1 e2, hg4, fun k p' hk' hp' => ?_⟩
      by_cases hki : k = i.val.toNat
      · subst hki
        rw [List.getElem?_eq_getElem hpl, hpv] at hp'
        cases hp'
        exact ⟨g, g1, hg, vg_extends_trans e1 e2, e2, hq⟩
      · exact hk k p' (by rw [hs.2]; omega) hp'
  · rename_i hge
    simp only [i32_lt_iff, not_lt] at hge
    have e := ok_inj' hb
    subst e
    simp only at hc
    subst hc
    refine ⟨fun c hc' => (by cases hc'), fun j g4 hr => ?_⟩
    cases hr
    refine ⟨vg_extends_refl _, hg, fun k p hk hp => ?_⟩
    rw [List.getElem?_eq_none (by omega)] at hp
    cases hp

theorem condAgree_restrict {W : Type} {vg vg' : ValGraph} (hp : vg_extends vg vg') {env : SymEnv}
    {vids : List Std.I32} {o : WorldOracle W} {regs : Nat → BitVec 64} {t : Term}
    (h : CondAgree vg' env vids o regs t) : CondAgree vg env vids o regs t := by
  cases t with
  | Jnz c s1 s2 =>
    unfold CondAgree AtomAgree at h ⊢
    obtain ⟨hs, ha⟩ := h
    exact ⟨hs, fun t ht v hv hval => by rw [ha t ht v hv (extends_valid hp hval), extends_evI hp env hval]⟩
  | _ => trivial

theorem factOK_restrict {vg vg' : ValGraph} (hp : vg_extends vg vg') {env : SymEnv} {fa : Fact}
    (hv : Valid vg fa.vid) (h : FactOK vg' env fa) : FactOK vg env fa := by
  obtain ⟨-, h1, h2⟩ := h
  exact ⟨hv, by rw [← extends_evI hp env hv]; exact h1, by rw [← extends_evI hp env hv]; exact h2⟩

theorem stable_transport {vg G : ValGraph} (hp : vg_extends vg G) {vids : List Std.I32} (_hv : VidsOK vg vids)
    {x : Nat} {v sb : Std.I32} (_hx : vids[x]? = some v) (_h0 : 0 ≤ v.val)
    (hm : Valid vg v ∧ Indep vg sb v.val.toNat) :
    ∀ env env', AgreeExcept sb env env' → evI G env' v = evI G env v := by
  intro env env' hag
  rw [extends_evI hp env' hm.1, extends_evI hp env hm.1]
  exact hm.2 env env' hag

/-- `cert_fail_code` returning `0`: the source and target contexts in the final graph, every pair
replayed in it, and the first pair at the two entries. -/
theorem cert_ctx {src tgt : Func} {cert : Cert} (h : cert_fail_code src tgt cert = ok 0#i32) :
    ∃ si ti G, SrcCtx G src si cert.svid.val cert.facts.val cert.savail ∧
      TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val ∧ PairsOK G src tgt cert si ti ∧
      ∃ p, cert.pairs.val[0]? = some p ∧ p.sb = 0#i32 ∧ p.tb = 0#i32 := by
  unfold cert_fail_code at h
  obtain ⟨w1, hw1, h⟩ := bind_eq_ok h
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  cases t2 with
  | true => simp only [↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | false => ?_
  simp only [Bool.false_eq_true, ↓reduceIte] at h
  have hwf : w1 = 0#i32 ∧ wf_code tgt = ok 0#i32 := by
    by_cases hw0 : w1 = 0#i32
    · subst hw0
      rw [ite_eq_right (fun hc : (0#i32 : Std.I32) ≠ 0#i32 => hc rfl)] at ht2
      obtain ⟨w2, hw2, ht2⟩ := bind_eq_ok ht2
      have e := ok_inj' ht2
      refine ⟨rfl, ?_⟩
      rw [hw2]; congr 1; simpa using e
    · rw [ite_eq_left hw0] at ht2; cases ok_inj' ht2
  obtain ⟨hw10, hwt⟩ := hwf
  rw [hw10] at hw1
  have WS := wf_code_sound hw1
  have WT := wf_code_sound hwt
  obtain ⟨t3, ht3, h⟩ := bind_eq_ok h
  cases t3 with
  | false => simp only [Bool.not_false, ↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | true => ?_
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
  have hdag := check_vg_dag_sound ht3
  obtain ⟨si, hsi, h⟩ := bind_eq_ok h
  obtain ⟨ti, hti, h⟩ := bind_eq_ok h
  have IS := build_info_sound hsi
  have IT := build_info_sound hti
  obtain ⟨t6, ht6, h⟩ := bind_eq_ok h
  obtain ⟨t8, ht8, h⟩ := bind_eq_ok h
  cases t8 with
  | true => simp only [↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | false => ?_
  simp only [Bool.false_eq_true, ↓reduceIte] at h
  have hvids : vids_ok cert.vg cert.svid si.nt = ok true ∧ vids_ok cert.vg cert.tvid ti.nt = ok true := by
    cases t6 with
    | false =>
      simp only [Bool.not_false, ↓reduceIte] at ht8
      all_goals cases ok_inj' ht8
    | true =>
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at ht8
      obtain ⟨t7, ht7, ht8⟩ := bind_eq_ok ht8
      cases t7 with
      | false => cases ok_inj' ht8
      | true => exact ⟨ht6, ht7⟩
  obtain ⟨hsl, hsn0, hsv⟩ := vids_ok_sound hvids.1
  obtain ⟨htl, -, htv⟩ := vids_ok_sound hvids.2
  obtain ⟨q10, hq10, h⟩ := bind_eq_ok h
  obtain ⟨t10, vg1⟩ := q10
  try simp only [uncurry_apply_pair] at h
  cases t10 with
  | false => simp only [Bool.not_false, ↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | true => ?_
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨e1, d1, hsd⟩ := check_src_defs_sound hq10 rfl hdag IS hsv
  obtain ⟨q12, hq12, h⟩ := bind_eq_ok h
  obtain ⟨t12, vg2⟩ := q12
  try simp only [uncurry_apply_pair] at h
  cases t12 with
  | false => simp only [Bool.not_false, ↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | true => ?_
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
  obtain ⟨e2, d2, htd⟩ := check_tgt_defs_sound hq12 rfl d1 IT (vidsOK_extends e1 htv)
  obtain ⟨ids, hids, h⟩ := bind_eq_ok h
  obtain ⟨t14, ht14, h⟩ := bind_eq_ok h
  by_cases h14 : t14 = 0#i32
  swap
  · rw [ite_eq_left h14] at h; exact absurd (ok_inj' h) (by decide)
  rw [ite_eq_right (not_not.mpr h14)] at h
  rw [h14] at ht14
  have AS := check_avail_sound ht14 IS
  obtain ⟨t15, ht15, h⟩ := bind_eq_ok h
  by_cases h15 : t15 = 0#i32
  swap
  · rw [ite_eq_left h15] at h; exact absurd (ok_inj' h) (by decide)
  rw [ite_eq_right (not_not.mpr h15)] at h
  rw [h15] at ht15
  have AT := check_avail_sound ht15 IT
  have hv2s : VidsOK vg2 cert.svid.val := vidsOK_extends (vg_extends_trans e1 e2) hsv
  have hv2t : VidsOK vg2 cert.tvid.val := vidsOK_extends (vg_extends_trans e1 e2) htv
  obtain ⟨q17, hq17, h⟩ := bind_eq_ok h
  obtain ⟨t17, vg3⟩ := q17
  try simp only [uncurry_apply_pair] at h
  by_cases h17 : t17 = 0#i32
  swap
  · rw [ite_eq_left h17] at h; exact absurd (ok_inj' h) (by decide)
  rw [ite_eq_right (not_not.mpr h17)] at h
  obtain ⟨e3, d3, hfa⟩ := check_facts_sound hq17 h17 d2 IS hv2s
  dsimp only at e3 d3 hfa
  -- the first pair
  obtain ⟨n18, hn18, h⟩ := bind_eq_ok h
  obtain ⟨t20, ht20, h⟩ := bind_eq_ok h
  obtain ⟨t22, ht22, h⟩ := bind_eq_ok h
  cases t22 with
  | true => simp only [↓reduceIte] at h; exact absurd (ok_inj' h) (by decide)
  | false => ?_
  simp only [Bool.false_eq_true, ↓reduceIte] at h
  have hp0 : ∃ p, cert.pairs.val[0]? = some p ∧ p.sb = 0#i32 ∧ p.tb = 0#i32 := by
    cases t20 with
    | true => simp only [↓reduceIte] at ht22; cases ok_inj' ht22
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at ht22
      obtain ⟨pa, hpa, ht22⟩ := bind_eq_ok ht22
      have h22 := ok_inj' ht22
      split at ht20
      · cases ok_inj' ht20
      obtain ⟨pb, hpb, ht20⟩ := bind_eq_ok ht20
      have h20 := ok_inj' ht20
      rw [hpa] at hpb
      have epb := ok_inj' hpb
      subst epb
      obtain ⟨-, hl, hv⟩ := arr_get_ok hpa
      have hg := List.getElem?_eq_getElem hl
      rw [hv] at hg
      exact ⟨pa, by simpa using hg, by simpa using h20, by simpa using h22⟩
  -- the contexts, in any DAG extending `vg3`
  have hb0 : 0 ≤ si.nb.val := by rw [IS.nb]; omega
  have mkCtx : ∀ G, vg_extends vg3 G → ValGraphDAG G →
      SrcCtx G src si cert.svid.val cert.facts.val cert.savail ∧
      TgtCtx G tgt ti cert.tvid.val cert.tavail cert.bm_t.val cert.bm_s.val := by
    intro G e4 d4
    have E3 : vg_extends vg3 G := e4
    have E2 : vg_extends vg2 G := vg_extends_trans e3 e4
    have E1 : vg_extends vg1 G := vg_extends_trans e2 E2
    refine ⟨⟨WS, IS, d4, vidsOK_extends E2 hv2s, hsl, hsn0, fun b hb => srcDefsBlk_extends E1 (hsd b hb),
      ?_, fun b B hr hB => AS.block b B hr hB, AS.entry, ?_⟩,
      ⟨WT, IT, d4, vidsOK_extends E2 hv2t, htl, ?_, ?_, fun b B hr hB => AT.block b B hr hB, AT.entry⟩⟩
    · intro b hr hbl x hx hav v hv hv0
      have hib : ids.val[b]? = some (i32n b) := iota_sound hids hb0 b (by rw [IS.nb]; omega)
      exact stable_transport E2 hv2s hv hv0 (AS.scope b hr hbl b (i32n b) hib hib x hx hav v hv hv0)
    · intro fa hfm
      obtain ⟨h1, h2, h3, hval, hst, himp⟩ := hfa fa hfm
      refine ⟨h1, h2, h3, extends_valid E3 hval, fun env env' hag => ?_,
        fun pb B hr hB hs W o regs env hca het hfb => ?_⟩
      · rw [extends_evI E3 env' hval, extends_evI E3 env hval]; exact hst env env' hag
      · exact factOK_extends E3 (himp pb B hr hB hs o regs env (condAgree_restrict E2 hca) het
          (fun fb hfb' hb => factOK_restrict E3 (hfa fb hfb').2.2.2.1 (hfb fb hfb' hb)))
    · intro b B hB i hi v h0 hv hv0 hc
      obtain ⟨hval, hpd⟩ := htd b B hB i hi v h0 hv hv0 hc
      exact ⟨extends_valid E2 hval, pureDef_extends E2 hval hpd⟩
    · intro b hr hbl j sb h1 h2 x hx hav v hv hv0
      exact stable_transport E2 hv2t hv hv0 (AT.scope b hr hbl j sb h1 h2 x hx hav v hv hv0)
  -- the pairs
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have hg3 : GPre cert vg3 :=
    ⟨d3, vidsOK_extends e3 hv2s, vidsOK_extends e3 hv2t, fun fb hm => (hfa fb hm).2.2.2.1⟩
  obtain ⟨CS3, CT3⟩ := mkCtx vg3 (vg_extends_refl _) d3
  have hL3 := pairs_loop CS3 CT3 _ _ hs (by simp) hg3
  cases s with
  | inl c => simp only at h; exact absurd (ok_inj' h) (hL3.1 c rfl)
  | inr y =>
    obtain ⟨j, vg4⟩ := y
    obtain ⟨e4, hg4, -⟩ := hL3.2 j vg4 rfl
    obtain ⟨CS, CT⟩ := mkCtx vg4 e4 hg4.1
    obtain ⟨-, -, hk⟩ := (pairs_loop CS CT _ _ hs (by simp) hg3).2 j vg4 rfl
    exact ⟨si, ti, vg4, CS, CT, fun k p hp => hk k p (by simp) hp, hp0⟩

theorem src_start {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail) {W : Type} (o : WorldOracle W)
    (args : List (BitVec 64)) (base : SymEnv) (s0 : MState W) {Bs : Block}
    (hBs : src.blocks.val[0]? = some Bs)
    (hsym : base.symAddr = o.symAddr) (hpar : ∀ c k, base.paramVal c k = argVal args k) :
    SIn G src si svid facts savail o args (enterEnv o args base (i32n 0) Bs (-1) s0.regs s0) 0 Bs s0 s0 0 ∧
      SHist G src si svid facts savail o (enterEnv o args base (i32n 0) Bs (-1) s0.regs s0) 0 := by
  refine ⟨⟨C.info.reach0, hBs, Nat.zero_le _,
    fun fa hfa hb => absurd hb (by have := (C.facts fa hfa).1; omega), ?_, by simp [execInsts], ?_, hsym,
    hpar⟩, Or.inl rfl⟩
  · intro t ht
    obtain ⟨htn, hc⟩ := ht
    rcases hc with h1 | ⟨P, hP, -⟩ | ⟨k, hk, -⟩
    · exact absurd h1 (C.entry t htn)
    · rw [C.wf.entry_nophi Bs hBs] at hP; cases hP
    · omega
  · intro c i inst _ hii hl
    have hil' : i < Bs.insts.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hii; cases hii
    obtain ⟨⟨-, hil⟩, -⟩ := C.defs (i32n 0) (by rw [i32n_val (by omega)]; omega) Bs
      (by rw [i32n_toNat (by omega)]; exact hBs)
    have hidx : idx Bs.insts.val (i32n i) = some inst := by
      unfold idx
      rw [ite_eq_left (by rw [i32n_val (by omega)]; omega), i32n_toNat (by omega)]
      exact hii
    rw [enterEnv_eff o args base (i32n 0) Bs (-1) s0.regs s0 c (i32n i) inst hidx hl, i32n_toNat (by omega)]

theorem tgt_start {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {W : Type} (env : SymEnv)
    (ts : MState W) {Bt : Block} (hBt : tgt.blocks.val[0]? = some Bt) (schain : List Std.I32) :
    TIn G tgt ti tvid tavail env 0 Bt ts 0 schain := by
  refine ⟨C.info.reach0, hBt, Nat.zero_le _, ?_, fun k hk hk0 => absurd hk0 (Nat.not_lt_zero _)⟩
  intro t ht
  obtain ⟨htn, hc⟩ := ht
  rcases hc with h1 | ⟨P, hP, -⟩ | ⟨k, hk, -⟩
  · exact absurd h1 (C.entry t htn)
  · rw [C.wf.entry_nophi Bt hBt] at hP; cases hP
  · omega

/-- **Soundness of the certificate checker**: if `verify_cert` accepts `cert`, every run of the
source that ends (returns or halts) is matched by a run of the target with the same outcome and
the same world. -/
theorem verify_cert_sound {W : Type} (src tgt : Func) (cert : Cert) (oracle : WorldOracle W)
    (args : List (BitVec 64)) (w0 : W) (fuel : Nat) (res : TermOutcome W)
    (hv : verify_cert src tgt cert = ok true)
    (hsrc : evalFunc src oracle args w0 fuel = some res) :
    ∃ fuel', evalFunc tgt oracle args w0 fuel' = some res := by
  unfold verify_cert at hv
  obtain ⟨c, hc, hv⟩ := bind_eq_ok hv
  have hc0 : c = 0#i32 := (i32_beq_iff _ _).1 (ok_inj' hv)
  subst hc0
  obtain ⟨si, ti, G, CS, CT, hpairs, p, hp, hpsb, hptb⟩ := cert_ctx hc
  cases fuel with
  | zero => simp [evalFunc, evalFrom] at hsrc
  | succ N =>
    unfold evalFunc at hsrc
    rw [evalFrom_succ] at hsrc
    split at hsrc
    · cases hsrc
    rename_i Bs hBs
    rw [CS.wf.entry_nophi Bs hBs] at hsrc
    let s0 : MState W := { regs := fun _ => 0, world := w0 }
    have hrun : restFrom oracle args src N 0 Bs 0 s0 = some res := hsrc
    let base : SymEnv := SymEnv.mk (fun _ k => argVal args k) (fun _ _ _ => 0) (fun _ _ _ => 0) oracle.symAddr
    obtain ⟨hin, hhist⟩ := src_start CS oracle args base s0 hBs rfl (fun _ _ => rfl)
    obtain ⟨Bt, hBt⟩ : ∃ Bt, tgt.blocks.val[0]? = some Bt :=
      ⟨_, List.getElem?_eq_getElem CT.wf.len_pos⟩
    have htin := tgt_start CT (enterEnv oracle args base (i32n 0) Bs (-1) s0.regs s0) s0 hBt [p.sb]
    have hsb : p.sb.val.toNat = 0 := by rw [hpsb]; decide
    have htb : p.tb.val.toNat = 0 := by rw [hptb]; decide
    obtain ⟨m, hm⟩ := pair_sim CS CT hpairs oracle args res N 0 p _ s0 s0 Bs Bt hp
      (by rw [hpsb]; decide) (by rw [hptb]; decide) (by rw [hsb]; exact hin) (by rw [hsb]; exact hhist)
      (by rw [hsb]; exact hrun) (by rw [htb]; exact htin) rfl ⟨rfl, fun _ _ => rfl⟩
    rw [htb] at hm
    refine ⟨m + 1, ?_⟩
    unfold evalFunc
    rw [evalFrom_succ, hBt]
    dsimp only
    rw [CT.wf.entry_nophi Bt hBt]
    exact hm

/-- **End-to-end soundness of the translation validator**: if `validate_fn` accepts the pair, every
terminating run of the source is matched by a run of the target with the same outcome. -/
theorem validate_fn_sound {W : Type} (src tgt : Func) (oracle : WorldOracle W)
    (args : List (BitVec 64)) (w0 : W) (fuel : Nat) (res : TermOutcome W)
    (hv : validate_fn src tgt = ok true)
    (hsrc : evalFunc src oracle args w0 fuel = some res) :
    ∃ fuel', evalFunc tgt oracle args w0 fuel' = some res := by
  unfold validate_fn at hv
  obtain ⟨oc, -, hv⟩ := bind_eq_ok hv
  cases oc with
  | none => simp only at hv; cases ok_inj' hv
  | some cert =>
    simp only at hv
    obtain ⟨b, hb, hv⟩ := bind_eq_ok hv
    have := ok_inj' hv
    subst this
    exact verify_cert_sound src tgt cert oracle args w0 fuel res hb hsrc

end PionProofs.QbeTvP
