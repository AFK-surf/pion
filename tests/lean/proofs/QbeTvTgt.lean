/-
The target side of the simulation behind `verify_cert_sound`: registers of the target agree
with `tvid` in the environment of the source run, and keep agreeing when the source enters a
block the replay allows.
-/
import PionProofs.QbeTvChecks
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-- What `verify_cert` establishes about the target, in the final value graph `G`. -/
structure TgtCtx (G : ValGraph) (tgt : Func) (ti : FnInfo) (tvid : List Std.I32) (tavail : Pion.Array Bool)
    (bm_t bm_s : List Std.I32) : Prop where
  wf : WFc tgt
  info : InfoOK tgt ti
  dag : ValGraphDAG G
  vids : VidsOK G tvid
  nt : tvid.length = ti.nt.val.toNat
  defs : ∀ (b : Nat) (B : Block), tgt.blocks.val[b]? = some B → ∀ i (hi : i < B.insts.val.length), ∀ v,
    0 ≤ (instDst B.insts.val[i]).val → tvid[(instDst B.insts.val[i]).val.toNat]? = some v →
    0 ≤ v.val → TgtChecked B.insts.val[i] → Valid G v ∧ PureDef G tvid B.insts.val[i] v
  scope : ∀ b, ti.reach.val[b]? = some true → b < tgt.blocks.val.length →
    ∀ (j : Nat) (sb : Std.I32), bm_t[j]? = some (i32n b) → bm_s[j]? = some sb →
    ∀ x, x < ti.nt.val.toNat → AvB tavail ti.nt b x → ∀ v, tvid[x]? = some v → 0 ≤ v.val →
      ∀ env env', AgreeExcept sb env env' → evI G env' v = evI G env v
  block : ∀ b (B : Block), ti.reach.val[b]? = some true → tgt.blocks.val[b]? = some B →
    BlockAvail tgt ti.nt tavail b B
  entry : ∀ t, t < ti.nt.val.toNat → ¬ AvB tavail ti.nt 0 t

/-- The target inside block `tb` (`Bt`) after its phis and its first `tx` instructions, in the
environment `env` of the source run; `schain` are the source blocks of the current pair. -/
structure TIn (G : ValGraph) (tgt : Func) (ti : FnInfo) (tvid : List Std.I32) (tavail : Pion.Array Bool)
    (env : SymEnv) (tb : Nat) (Bt : Block) {W : Type} (ts : MState W) (tx : Nat) (schain : List Std.I32) :
    Prop where
  reach : ti.reach.val[tb]? = some true
  blk : tgt.blocks.val[tb]? = some Bt
  le : tx ≤ Bt.insts.val.length
  regs : RegsAgree G env (CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt tx) tvid ts.regs
  stab : ∀ k (hk : k < Bt.insts.val.length), k < tx → ∀ v, 0 ≤ (instDst Bt.insts.val[k]).val →
    tvid[(instDst Bt.insts.val[k]).val.toNat]? = some v → Valid G v →
    PureDef G tvid Bt.insts.val[k] v ∨ ∃ c sb i, sb ∈ schain ∧ nodeAt G v = some (.SEffect c sb i)

/-- A value is the same in two environments differing only at block `sj`. -/
def StableAt (G : ValGraph) (sj : Std.I32) (v : Std.I32) : Prop :=
  ∀ env env', AgreeExcept sj env env' → evI G env' v = evI G env v

theorem atomSem_stable {G : ValGraph} {vids : List Std.I32} {a : Atom} {sj : Std.I32}
    (hk : AtomKnown G vids a) (hst : ∀ t, a = .Temp t → ∀ v, vids[t.val.toNat]? = some v → Valid G v → StableAt G sj v)
    {env env' : SymEnv} (ha : AgreeExcept sj env env') : atomSem G env' vids a = atomSem G env vids a := by
  cases a with
  | Temp t =>
    obtain ⟨h0, w, hw, hv⟩ := hk t rfl
    simp only [atomSem, h0, ↓reduceIte, hw]
    exact hst t rfl w hw hv env env' ha
  | Const _ => rfl
  | Sym s off => simp only [atomSem, ha.2.1]

theorem pureDef_stable {G : ValGraph} {vids : List Std.I32} {inst : Inst} {v : Std.I32} {sj : Std.I32}
    (hp : PureDef G vids inst v)
    (hst : ∀ a, (∃ d c op, inst = .Un d c op a) ∨ (∃ d c op b, inst = .Bin d c op a b ∨ inst = .Bin d c op b a) →
      ∀ t, a = .Temp t → ∀ w, vids[t.val.toNat]? = some w → Valid G w → StableAt G sj w) :
    StableAt G sj v := by
  intro env env' ha
  cases inst with
  | Par d c k => rw [hp env, hp env', ha.1]
  | Un d c op a =>
    rw [hp.2 env, hp.2 env', atomSem_stable hp.1 (hst a (Or.inl ⟨d, c, op, rfl⟩)) ha]
  | Bin d c op a b =>
    have e1 := hp.2.2 env
    have e2 := hp.2.2 env'
    rw [atomSem_stable hp.1 (hst a (Or.inr ⟨d, c, op, b, Or.inl rfl⟩)) ha,
      atomSem_stable hp.2.1 (hst b (Or.inr ⟨d, c, op, a, Or.inr rfl⟩)) ha, e1] at e2
    exact (Option.some.inj e2).symm
  | _ => exact absurd hp (by simp [PureDef])

/-- The temps the target has initialised in its current block keep their values when the source
enters a block `sj` outside the pair, given the checks on the block's entry. -/
theorem tgt_stable {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {env : SymEnv} {tb : Nat}
    {Bt : Block} {W : Type} {ts : MState W} {tx : Nat} {schain : List Std.I32}
    (hin : TIn G tgt ti tvid tavail env tb Bt ts tx schain) {sj : Std.I32} (hsj : sj ∉ schain)
    (havail : ∀ x, x < ti.nt.val.toNat → AvB tavail ti.nt tb x → ∀ v, tvid[x]? = some v → Valid G v →
      StableAt G sj v)
    (hphis : ∀ P ∈ Bt.phis.val, ∀ v, tvid[P.dst.val.toNat]? = some v → Valid G v → StableAt G sj v) :
    ∀ t, CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt tx t → ∀ v, tvid[t]? = some v → Valid G v →
      StableAt G sj v := by
  obtain ⟨-, hinsts, -, -⟩ := C.block tb Bt hin.reach hin.blk
  suffices key : ∀ k, k ≤ tx → ∀ t, CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt k t → ∀ v,
      tvid[t]? = some v → Valid G v → StableAt G sj v from key tx (le_refl _)
  intro k
  induction k with
  | zero =>
    intro _ t ht v hv hvv
    rcases ht.2 with h1 | ⟨P, hP, hPd⟩ | ⟨k, hk, -⟩
    · exact havail t ht.1 h1 v hv hvv
    · exact hphis P hP v (by rw [show P.dst.val.toNat = t by omega]; exact hv) hvv
    · omega
  | succ k ih =>
    intro hk t ht v hv hvv
    by_cases hold : CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt k t
    · exact ih (by omega) t hold v hv hvv
    obtain ⟨htn, hcase⟩ := ht
    rcases hcase with h1 | h1 | ⟨k', hk', hkl, hkd⟩
    · exact absurd ⟨htn, Or.inl h1⟩ hold
    · exact absurd ⟨htn, Or.inr (Or.inl h1)⟩ hold
    have hkk : k' = k := by
      by_contra hne
      exact hold ⟨htn, Or.inr (Or.inr ⟨k', by omega, hkl, hkd⟩)⟩
    subst hkk
    have hd0 : 0 ≤ (instDst Bt.insts.val[k']).val := by omega
    have hvt : tvid[(instDst Bt.insts.val[k']).val.toNat]? = some v := by
      rw [show (instDst Bt.insts.val[k']).val.toNat = t by omega]; exact hv
    rcases hin.stab k' hkl (by omega) v hd0 hvt hvv with hpd | ⟨c, sb, i, hsb, hn⟩
    · apply pureDef_stable hpd
      intro a ha t' ht' w hw hvw
      have hav := (hinsts k' hkl).1
      have hcur : CurAt ti.nt.val.toNat (AvB tavail ti.nt tb) Bt k' t'.val.toNat := by
        rcases ha with ⟨d, c, op, he⟩ | ⟨d, c, op, b, he | he⟩
        · rw [he] at hav; subst ht'; exact hav.2
        · rw [he] at hav; subst ht'; exact hav.1.2
        · rw [he] at hav; subst ht'; exact hav.2.2
      exact ih (by omega) _ hcur w hw hvw
    · intro e e' ha
      have hne : sb ≠ sj := fun h => hsj (h ▸ hsb)
      rw [evI_node C.dag e hn, evI_node C.dag e' hn]
      simp only [evalNode]
      rw [ha.2.2.2 c sb i hne]

/-- One instruction of the target, whose result (if it has a known value) has that value. -/
theorem tgt_step {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {env : SymEnv} {tb : Nat}
    {Bt : Block} {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {ts ts' : MState W} {tx : Nat}
    {schain : List Std.I32}
    (hin : TIn G tgt ti tvid tavail env tb Bt ts tx schain) (hx : tx < Bt.insts.val.length)
    (h : execInst o args ts Bt.insts.val[tx] = some ts')
    (hval : ∀ v, 0 ≤ (instDst Bt.insts.val[tx]).val → tvid[(instDst Bt.insts.val[tx]).val.toNat]? = some v →
      Valid G v → ts'.regs (instDst Bt.insts.val[tx]).val.toNat = evI G env v ∧
        (PureDef G tvid Bt.insts.val[tx] v ∨ ∃ c sb i, sb ∈ schain ∧ nodeAt G v = some (.SEffect c sb i))) :
    TIn G tgt ti tvid tavail env tb Bt ts' (tx + 1) schain := by
  have hdst := C.wf.dsts tb Bt hin.blk Bt.insts.val[tx] (List.getElem_mem _)
  refine ⟨hin.reach, hin.blk, by omega, fun t ht v hv hvv => ?_, fun k hk hkl v hd0 hv hvv => ?_⟩
  · by_cases hdt : 0 ≤ (instDst Bt.insts.val[tx]).val ∧ (instDst Bt.insts.val[tx]).val.toNat = t
    · obtain ⟨hd0, rfl⟩ := hdt
      exact (hval v hd0 hv hvv).1
    · have ht' : (instDst Bt.insts.val[tx]).val.toNat ≠ t ∨ (instDst Bt.insts.val[tx]).val < 0 := by
        by_cases h0 : 0 ≤ (instDst Bt.insts.val[tx]).val
        · exact Or.inl (fun e => hdt ⟨h0, e⟩)
        · exact Or.inr (by omega)
      rw [execInst_regs hdst h t ht']
      refine hin.regs t ⟨ht.1, ?_⟩ v hv hvv
      rcases ht.2 with h1 | h1 | ⟨k, hk, hkl, hkd⟩
      · exact Or.inl h1
      · exact Or.inr (Or.inl h1)
      · right; right
        by_cases hkx : k = tx
        · subst hkx
          exfalso; apply hdt
          exact ⟨by omega, by omega⟩
        · exact ⟨k, by omega, hkl, hkd⟩
  · by_cases hkx : k = tx
    · subst hkx
      exact (hval v hd0 hv hvv).2
    · exact hin.stab k hk (by omega) v hd0 hv hvv

theorem execPhis_some {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (prev : Int) :
    ∀ (ps : List Phi) (acc : Nat → BitVec 64), (∀ P ∈ ps, ∃ a, phiArg P prev = some a) →
      ∃ R, execPhis o regs prev ps acc = some R
  | [], acc, _ => ⟨acc, rfl⟩
  | P :: ps, acc, h => by
    obtain ⟨a, ha⟩ := h P List.mem_cons_self
    obtain ⟨R, hR⟩ := execPhis_some o regs prev ps _ (fun P' hP' => h P' (List.mem_cons_of_mem _ hP'))
    exact ⟨R, by simp only [execPhis, ha, Option.bind_some]; exact hR⟩

/-- The target enters block `tj` from `tc`: its phis take values the environment `env'` gives
their destinations, the other temps it keeps have the same values in `env'` as in `env`. -/
theorem tgt_enter {G : ValGraph} {tgt : Func} {ti : FnInfo} {tvid : List Std.I32} {tavail : Pion.Array Bool}
    {bm_t bm_s : List Std.I32} (C : TgtCtx G tgt ti tvid tavail bm_t bm_s) {env env' : SymEnv} {tc : Nat}
    {Bt : Block} {W : Type} {o : WorldOracle W} {ts : MState W} {schain schain' : List Std.I32}
    (hin : TIn G tgt ti tvid tavail env tc Bt ts Bt.insts.val.length schain) {tj : Std.I32}
    (hedge : EdgeTaken o ts.regs Bt.term tj) {Bj : Block} (hBj : tgt.blocks.val[tj.val.toNat]? = some Bj)
    (hphis : ∀ P ∈ Bj.phis.val, ∃ a, phiArg P tc = some a ∧
      ∀ v, tvid[P.dst.val.toNat]? = some v → Valid G v → atomVal o ts.regs P.cls a = evI G env' v)
    (hst : ∀ x, x < ti.nt.val.toNat → AvB tavail ti.nt tj.val.toNat x → ∀ v, tvid[x]? = some v →
      Valid G v → evI G env' v = evI G env v) :
    ∃ R, execPhis o ts.regs tc Bj.phis.val ts.regs = some R ∧
      TIn G tgt ti tvid tavail env' tj.val.toNat Bj { ts with regs := R } 0 schain' := by
  have hlen := C.wf.len_le
  have hts : tj ∈ termSuccs Bt.term := edgeTaken_mem hedge
  obtain ⟨-, -, -, hsucc⟩ := C.block tc Bt hin.reach hin.blk
  obtain ⟨htj0, htjl, hav, -⟩ := hsucc tj hts
  obtain ⟨R, hR⟩ := execPhis_some o ts.regs tc Bj.phis.val ts.regs (fun P hP => (hphis P hP).elim
    (fun a ha => ⟨a, ha.1⟩))
  obtain ⟨-, hRs⟩ := execPhis_spec o ts.regs tc Bj.phis.val ts.regs R hR
  have hreach : ti.reach.val[tj.val.toNat]? = some true :=
    C.info.closed tc Bt hin.blk hin.reach tj hts (by omega) htjl
  refine ⟨R, hR, hreach, hBj, Nat.zero_le _, fun t ht v hv hvv => ?_, fun k _ hkl => absurd hkl (by omega)⟩
  by_cases hex : ∃ P ∈ Bj.phis.val, P.dst.val.toNat = t
  · obtain ⟨P, hP, hPd, a, ha, hRt⟩ := (hRs t).2 hex
    obtain ⟨a', ha', hval⟩ := hphis P hP
    rw [ha] at ha'; cases ha'
    show R t = _
    rw [hRt]
    exact hval v (by rw [hPd]; exact hv) hvv
  · push Not at hex
    show R t = _
    rw [(hRs t).1 hex]
    obtain ⟨htn, hcase⟩ := ht
    have havb : AvB tavail ti.nt tj.val.toNat t := by
      rcases hcase with h1 | ⟨P, hP, hPd⟩ | ⟨k, hk, -⟩
      · exact h1
      · exact absurd (by omega) (hex P hP)
      · omega
    rw [hin.regs t (hav t htn havb) v hv hvv, hst t htn havb v hv hvv]

end PionProofs.QbeTvP
