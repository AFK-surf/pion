/-
The simulation behind `verify_cert_sound`: running a block of the source, the environment of
the value graph at each block entry, and what the checks of `verify_cert` give about the
registers of the source and the target at each point of a certified pair.
-/
import PionProofs.QbeTvReplay
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Running the rest of a block -/

section Run
variable {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (f : Func)

/-- The terminator of block `b`, then the rest of the run with `n` more blocks. -/
def termCont (n : Nat) (b : Nat) (t : Term) (s : MState W) : Option (TermOutcome W) :=
  match t with
  | .Jmp d => (blockId d).bind fun d' => evalFrom o args f n b d' s
  | .Jnz a d1 d2 =>
    (blockId (if atomVal o s.regs .W a ≠ 0 then d1 else d2)).bind fun d' => evalFrom o args f n b d' s
  | .Ret has c a => some (.ret (if has then some (atomVal o s.regs c a) else none) s.world)
  | .Hlt => some (.hlt s.world)

/-- The instructions of block `b` (`B`) from the `x`-th on, its terminator, then the rest of
the run with `n` more blocks. -/
def restFrom (n : Nat) (b : Nat) (B : Block) (x : Nat) (s : MState W) : Option (TermOutcome W) :=
  (execInsts o args (B.insts.val.drop x) s).bind (termCont o args f n b B.term)

theorem evalFrom_succ (n : Nat) (prev : Int) (b : Nat) (s : MState W) :
    evalFrom o args f (n + 1) prev b s = match f.blocks.val[b]? with
      | none => none
      | some B => (execPhis o s.regs prev B.phis.val s.regs).bind fun regs =>
          restFrom o args f n b B 0 { s with regs := regs } := by
  rw [evalFrom]
  unfold runBlock
  cases hB : f.blocks.val[b]? with
  | none => rfl
  | some B =>
    simp only
    cases hp : execPhis o s.regs prev B.phis.val s.regs with
    | none => rfl
    | some regs =>
      simp only [Option.bind_some, restFrom, List.drop_zero]
      cases hi : execInsts o args B.insts.val { s with regs := regs } with
      | none => rfl
      | some s' => cases B.term <;> rfl

theorem restFrom_step {n b : Nat} {B : Block} {x : Nat} {s : MState W} (hx : x < B.insts.val.length) :
    restFrom o args f n b B x s =
      (execInst o args s B.insts.val[x]).bind (restFrom o args f n b B (x + 1)) := by
  unfold restFrom
  rw [List.drop_eq_getElem_cons hx]
  simp only [execInsts, Option.bind_assoc]

theorem restFrom_end {n b : Nat} {B : Block} {s : MState W} :
    restFrom o args f n b B B.insts.val.length s = termCont o args f n b B.term s := by
  unfold restFrom
  rw [List.drop_length]
  rfl

theorem termCont_fuel {n b : Nat} {t : Term} {s : MState W} {r : TermOutcome W}
    (h : termCont o args f n b t s = some r) : termCont o args f (n + 1) b t s = some r := by
  unfold termCont at h ⊢
  cases t with
  | Jmp d =>
    simp only at h ⊢
    cases hd : blockId d with
    | none => rw [hd] at h; simp at h
    | some d' => rw [hd] at h; simp only [Option.bind_some] at h ⊢; exact evalFrom_fuel o args f _ _ _ _ _ h
  | Jnz a d1 d2 =>
    simp only at h ⊢
    cases hd : blockId (if atomVal o s.regs .W a ≠ 0 then d1 else d2) with
    | none => rw [hd] at h; simp at h
    | some d' => rw [hd] at h; simp only [Option.bind_some] at h ⊢; exact evalFrom_fuel o args f _ _ _ _ _ h
  | Ret _ _ _ => exact h
  | Hlt => exact h

theorem restFrom_fuel {n b : Nat} {B : Block} {x : Nat} {s : MState W} {r : TermOutcome W}
    (h : restFrom o args f n b B x s = some r) : restFrom o args f (n + 1) b B x s = some r := by
  unfold restFrom at h ⊢
  cases hi : execInsts o args (B.insts.val.drop x) s with
  | none => rw [hi] at h; simp at h
  | some s' => rw [hi] at h; simp only [Option.bind_some] at h ⊢; exact termCont_fuel o args f h

theorem evalFrom_fuel_le {n m : Nat} (hnm : n ≤ m) {prev : Int} {b : Nat} {s : MState W}
    {r : TermOutcome W} (h : evalFrom o args f n prev b s = some r) : evalFrom o args f m prev b s = some r := by
  induction hnm with
  | refl => exact h
  | step _ ih => exact evalFrom_fuel o args f _ _ _ _ _ ih

theorem restFrom_fuel_le {n m : Nat} (hnm : n ≤ m) {b : Nat} {B : Block} {x : Nat} {s : MState W}
    {r : TermOutcome W} (h : restFrom o args f n b B x s = some r) : restFrom o args f m b B x s = some r := by
  induction hnm with
  | refl => exact h
  | step _ ih => exact restFrom_fuel o args f ih

/-- `execPhis`: a phi destination holds the value of some phi writing it; other temps keep
their value. -/
theorem execPhis_spec (regs : Nat → BitVec 64) (prev : Int) :
    ∀ (ps : List Phi) (acc R : Nat → BitVec 64), execPhis o regs prev ps acc = some R →
      (∀ P ∈ ps, ∃ a, phiArg P prev = some a) ∧
      ∀ t, ((∀ P ∈ ps, P.dst.val.toNat ≠ t) → R t = acc t) ∧
        ((∃ P ∈ ps, P.dst.val.toNat = t) → ∃ P ∈ ps, P.dst.val.toNat = t ∧
          ∃ a, phiArg P prev = some a ∧ R t = atomVal o regs P.cls a)
  | [], acc, R, h => by
    simp only [execPhis, Option.some.injEq] at h
    subst h
    exact ⟨fun P hP => by simp at hP, fun t => ⟨fun _ => rfl, fun ⟨P, hP, _⟩ => by simp at hP⟩⟩
  | P :: ps, acc, R, h => by
    simp only [execPhis] at h
    cases ha : phiArg P prev with
    | none => rw [ha] at h; simp at h
    | some a =>
      rw [ha] at h
      simp only [Option.bind_some] at h
      obtain ⟨hall, ih⟩ := execPhis_spec regs prev ps _ R h
      refine ⟨fun P' hP' => ?_, fun t => ⟨fun hn => ?_, fun _ => ?_⟩⟩
      · rcases List.mem_cons.1 hP' with rfl | hP'
        · exact ⟨a, ha⟩
        · exact hall P' hP'
      · rw [(ih t).1 (fun P' hP' => hn P' (List.mem_cons_of_mem _ hP'))]
        simp only [setReg]
        rw [ite_eq_right (fun e => hn P (List.mem_cons_self) e.symm)]
      · by_cases hex : ∃ P' ∈ ps, P'.dst.val.toNat = t
        · obtain ⟨P', hP', hd, a', ha', hR⟩ := (ih t).2 hex
          exact ⟨P', List.mem_cons_of_mem _ hP', hd, a', ha', hR⟩
        · push Not at hex
          rw [(ih t).1 hex]
          by_cases hpt : P.dst.val.toNat = t
          · refine ⟨P, List.mem_cons_self, hpt, a, ha, ?_⟩
            simp only [setReg, hpt, ↓reduceIte]
          · exfalso
            rename_i hpex
            obtain ⟨P', hP', hd⟩ := hpex
            rcases List.mem_cons.1 hP' with rfl | hP'
            · exact hpt hd
            · exact hex P' hP' hd

theorem phiArg_mem {P : Phi} {prev : Int} {a : Atom} (h : phiArg P prev = some a) :
    ∃ A ∈ P.arms.val, A.pred.val = prev ∧ A.value = a := by
  unfold phiArg at h
  cases hf : P.arms.val.find? (fun a => decide (a.pred.val = prev)) with
  | none => rw [hf] at h; simp at h
  | some A =>
    rw [hf] at h
    simp only [Option.map_some, Option.some.injEq] at h
    exact ⟨A, List.mem_of_find?_eq_some hf, by simpa using List.find?_some hf, h⟩

end Run

/-- `iota n`: the ids `0, …, n-1`. -/
theorem iota_sound {n : Std.I32} {xs : Pion.Array Std.I32} (h : iota n = ok xs) (hn : 0 ≤ n.val) :
    ∀ j, j < n.val.toNat → xs.val[j]? = some (i32n j) := by
  unfold iota at h
  obtain ⟨q, hq, h⟩ := bind_eq_ok h
  obtain ⟨i1, xs1⟩ := q
  simp only [uncurry_apply_pair] at h
  cases ok_inj' h
  unfold iota_loop0 at hq
  have key := loop_ok_inv (fun (x : Std.I32 × Pion.Array Std.I32) =>
      match x with | (i, xs) => iota_loop0.body n i xs)
    (fun x => 0 ≤ x.1.val ∧ x.1.val ≤ n.val ∧ x.2.val.length = n.val.toNat ∧
      ∀ j, j < x.1.val.toNat → x.2.val[j]? = some (i32n j))
    (fun y => ∀ j, j < n.val.toNat → y.2.val[j]? = some (i32n j))
    ?_ _ _ hq ⟨by simp, by simp; omega, by simp [Pion.Array.make, listMake], fun j hj => by simp at hj⟩
  · exact key
  rintro ⟨iI, xsI⟩ c ⟨hi0, hin, hl, hall⟩ hc
  try dsimp only at hi0 hin hl hall hc
  unfold iota_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : iI.val < n.val := by simpa [i32_lt_iff] using hlt
    obtain ⟨xs2, hxs2, hc⟩ := bind_eq_ok hc
    have hset := arr_set_ok hxs2
    rw [← ok_inj' hc]
    dsimp only
    have his := i32_succ_val hlt'
    refine ⟨by omega, by omega, by rw [hset, List.length_set, hl], fun j hj => ?_⟩
    rw [hset, List.getElem?_set]
    by_cases hji : iI.val.toNat = j
    · subst hji
      rw [ite_eq_left rfl, ite_eq_left (by omega)]
      simp only [Option.some.injEq]
      exact i32n_of_val hi0
    · rw [ite_eq_right hji]
      exact hall j (by omega)
  · rename_i hge
    have hge' : n.val ≤ iI.val := by simpa [i32_lt_iff] using hge
    rw [← ok_inj' hc]
    exact fun j hj => hall j (by omega)

/-! ## The environment of the value graph along a run -/

/-- `LeafInst` as a boolean. -/
def leafB : Inst → Bool
  | .Bin _ _ op _ _ => trapOp op
  | .Load _ _ _ _ _ => true
  | .Call _ _ _ _ _ => true
  | .Alloc _ _ _ => true
  | _ => false

theorem leafB_iff (inst : Inst) : leafB inst = true ↔ LeafInst inst := by
  cases inst <;> simp [leafB, LeafInst]

/-- `l[k]` for a non-negative `k`. -/
def idx {α : Type} (l : List α) (k : Std.I32) : Option α := if 0 ≤ k.val then l[k.val.toNat]? else none

section Env
variable {W : Type} (o : WorldOracle W) (args : List (BitVec 64))

/-- The value instruction `inst` writes to its destination from state `s`. -/
def instVal (s : MState W) (inst : Inst) : BitVec 64 :=
  match execInst o args s inst with
  | some s' => s'.regs (instDst inst).val.toNat
  | none => 0

/-- The value instruction `i` of block `B` writes when the block runs from `s0` (after its phis). -/
def effAt (B : Block) (s0 : MState W) (i : Nat) : BitVec 64 :=
  match execInsts o args (B.insts.val.take i) s0, B.insts.val[i]? with
  | some s, some inst => instVal o args s inst
  | _, _ => 0

/-- The value phi `P` takes on the edge from `prev`, read in `R`. -/
def phiValAt (R : Nat → BitVec 64) (prev : Int) (P : Phi) : BitVec 64 :=
  match phiArg P prev with
  | some a => atomVal o R P.cls a
  | none => 0

/-- The environment once block `blk` (`B`) is entered from `prev` (registers `R` there) and runs
from `s0`: its phi leaves and effect leaves take the values of this visit. -/
def enterEnv (env : SymEnv) (blk : Std.I32) (B : Block) (prev : Int) (R : Nat → BitVec 64)
    (s0 : MState W) : SymEnv where
  paramVal := env.paramVal
  symAddr := env.symAddr
  phiVal := fun c b k => if b = blk then
      (match idx B.phis.val k with
       | some P => phiValAt o R prev P
       | none => env.phiVal c b k)
    else env.phiVal c b k
  effVal := fun c b i => if b = blk then
      (match idx B.insts.val i with
       | some inst => if leafB inst then effAt o args B s0 i.val.toNat else env.effVal c b i
       | none => env.effVal c b i)
    else env.effVal c b i

theorem enterEnv_agree (env : SymEnv) (blk : Std.I32) (B : Block) (prev : Int) (R : Nat → BitVec 64)
    (s0 : MState W) : AgreeExcept blk env (enterEnv o args env blk B prev R s0) :=
  ⟨rfl, rfl, fun c b k hb => by simp [enterEnv, hb], fun c b k hb => by simp [enterEnv, hb]⟩

theorem enterEnv_trivial (env : SymEnv) (blk : Std.I32) (B : Block) (prev : Int) (R : Nat → BitVec 64)
    (s0 : MState W) (hp : B.phis.val = []) (hi : ∀ inst ∈ B.insts.val, leafB inst = false) :
    enterEnv o args env blk B prev R s0 = env := by
  cases env with
  | mk pv phv efv sa =>
    simp only [enterEnv, SymEnv.mk.injEq, true_and, and_true]
    constructor
    · funext c b k
      split
      · simp [idx, hp]
      · rfl
    · funext c b i
      split
      · split
        · rename_i inst hinst
          have hm : inst ∈ B.insts.val := by
            unfold idx at hinst
            split at hinst
            · exact List.mem_of_getElem? hinst
            · cases hinst
          simp [hi inst hm]
        · rfl
      · rfl

theorem enterEnv_phi (env : SymEnv) (blk : Std.I32) (B : Block) (prev : Int) (R : Nat → BitVec 64)
    (s0 : MState W) (c : Cls) (k : Std.I32) (P : Phi) (hk : idx B.phis.val k = some P) :
    (enterEnv o args env blk B prev R s0).phiVal c blk k = phiValAt o R prev P := by
  simp [enterEnv, hk]

theorem enterEnv_eff (env : SymEnv) (blk : Std.I32) (B : Block) (prev : Int) (R : Nat → BitVec 64)
    (s0 : MState W) (c : Cls) (i : Std.I32) (inst : Inst) (hi : idx B.insts.val i = some inst)
    (hl : leafB inst = true) :
    (enterEnv o args env blk B prev R s0).effVal c blk i = effAt o args B s0 i.val.toNat := by
  simp [enterEnv, hi, hl]

end Env

theorem atomVal_masked {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (c : Cls) (a : Atom) :
    maskC c (atomVal o regs c a) = atomVal o regs c a := maskC_idem _ _

theorem phiValAt_masked {W : Type} (o : WorldOracle W) (R : Nat → BitVec 64) (prev : Int) (P : Phi) :
    maskC P.cls (phiValAt o R prev P) = phiValAt o R prev P := by
  unfold phiValAt
  split
  · exact maskC_idem _ _
  · cases P.cls <;> rfl

/-! ## The source run -/

theorem i32n_toNat {b : Nat} (h : b < 2147483648) : (i32n b).val.toNat = b := by
  rw [i32n_val h]; simp

theorem edgeTaken_mem {W : Type} {o : WorldOracle W} {regs : Nat → BitVec 64} {t : Term} {s : Std.I32}
    (h : EdgeTaken o regs t s) : s ∈ termSuccs t := by
  cases t with
  | Jmp d => simp only [EdgeTaken] at h; simp [termSuccs, h]
  | Jnz a d1 d2 =>
    simp only [EdgeTaken] at h
    split at h <;> simp [termSuccs, h]
  | _ => exact absurd h (by simp [EdgeTaken])

/-- What `check_avail` gives about one reachable block. -/
def BlockAvail (f : Func) (nt : Std.I32) (av : Pion.Array Bool) (b : Nat) (B : Block) : Prop :=
  (∀ P ∈ B.phis.val, 0 ≤ P.dst.val ∧ P.dst.val < nt.val) ∧
  (∀ i (hi : i < B.insts.val.length),
    AvailInst (CurAt nt.val.toNat (AvB av nt b) B i) B.insts.val[i] ∧
    (0 ≤ (instDst B.insts.val[i]).val → (instDst B.insts.val[i]).val < nt.val)) ∧
  AvailTerm (CurAt nt.val.toNat (AvB av nt b) B B.insts.val.length) B.term ∧
  ∀ s ∈ termSuccs B.term, 0 < s.val ∧ s.val < f.blocks.val.length ∧
    (∀ z, z < nt.val.toNat → AvB av nt s.val.toNat z → CurAt nt.val.toNat (AvB av nt b) B B.insts.val.length z) ∧
    ∃ S, f.blocks.val[s.val.toNat]? = some S ∧ ∀ P ∈ S.phis.val, ∃ a, phiArg P b = some a ∧
      AvailAtom (CurAt nt.val.toNat (AvB av nt b) B B.insts.val.length) a

/-- What `verify_cert` establishes about the source, in the final value graph `G`. -/
structure SrcCtx (G : ValGraph) (src : Func) (si : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (savail : Pion.Array Bool) : Prop where
  wf : WFc src
  info : InfoOK src si
  dag : ValGraphDAG G
  vids : VidsOK G svid
  nt : svid.length = si.nt.val.toNat
  nt0 : 0 ≤ si.nt.val
  defs : ∀ b : Std.I32, 0 ≤ b.val → SrcDefsBlk G src si svid facts b
  scope : ∀ b, si.reach.val[b]? = some true → b < src.blocks.val.length →
    ∀ x, x < si.nt.val.toNat → AvB savail si.nt b x → ∀ v, svid[x]? = some v → 0 ≤ v.val →
      ∀ env env', AgreeExcept (i32n b) env env' → evI G env' v = evI G env v
  block : ∀ b (B : Block), si.reach.val[b]? = some true → src.blocks.val[b]? = some B →
    BlockAvail src si.nt savail b B
  entry : ∀ t, t < si.nt.val.toNat → ¬ AvB savail si.nt 0 t
  facts : ∀ fa ∈ facts, 0 < fa.blk.val ∧ fa.blk.val < src.blocks.val.length ∧
    si.reach.val[fa.blk.val.toNat]? = some true ∧ Valid G fa.vid ∧
    (∀ env env', AgreeExcept fa.blk env env' → evI G env' fa.vid = evI G env fa.vid) ∧
    ∀ (pb : Nat) (B : Block), si.reach.val[pb]? = some true → src.blocks.val[pb]? = some B →
      fa.blk ∈ termSuccs B.term → ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
        CondAgree G env svid o regs B.term → EdgeTaken o regs B.term fa.blk →
        (∀ fb ∈ facts, fb.blk.val = pb → FactOK G env fb) → FactOK G env fa

/-- The source at the end of block `b` (instructions done): registers agree with `svid` on the
temps initialised there, and the facts of `b` hold. -/
def SEnd (G : ValGraph) (src : Func) (si : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (savail : Pion.Array Bool) (env : SymEnv) (b : Nat) (regs : Nat → BitVec 64) : Prop :=
  si.reach.val[b]? = some true ∧ (∀ fa ∈ facts, fa.blk.val = b → FactOK G env fa) ∧
  ∃ B, src.blocks.val[b]? = some B ∧
    RegsAgree G env (CurAt si.nt.val.toNat (AvB savail si.nt b) B B.insts.val.length) svid regs

/-- How the run entered block `b`: it is the entry, or it came from a block `d` ending in the
state `SEnd`, its environment differing from the current one only at `b`. -/
def SHist (G : ValGraph) (src : Func) (si : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (savail : Pion.Array Bool) {W : Type} (o : WorldOracle W) (env : SymEnv) (b : Nat) : Prop :=
  b = 0 ∨ ∃ d regs_d env_d Bd, SEnd G src si svid facts savail env_d d regs_d ∧
    src.blocks.val[d]? = some Bd ∧ EdgeTaken o regs_d Bd.term (i32n b) ∧ AgreeExcept (i32n b) env_d env

theorem agree_of_avail {W : Type} {G : ValGraph} {env : SymEnv} {svid : List Std.I32}
    {o : WorldOracle W} {regs : Nat → BitVec 64} {cur : Nat → Prop} (hag : RegsAgree G env cur svid regs)
    (hsym : env.symAddr = o.symAddr) {a : Atom} (ha : AvailAtom cur a) : AtomAgree G env svid o regs a := by
  refine ⟨hsym, fun t ht v hv hvv => ?_⟩
  subst ht
  exact hag _ ha.2 v hv hvv

theorem condAgree_of_avail {W : Type} {G : ValGraph} {env : SymEnv} {svid : List Std.I32}
    {o : WorldOracle W} {regs : Nat → BitVec 64} {cur : Nat → Prop} (hag : RegsAgree G env cur svid regs)
    (hsym : env.symAddr = o.symAddr) {t : Term} (ha : AvailTerm cur t) : CondAgree G env svid o regs t := by
  cases t with
  | Jnz c _ _ => exact agree_of_avail hag hsym ha
  | _ => trivial

/-- The value of each phi of block `b` on entry from `p`, given by its `PhiDef`. -/
theorem src_phi_sem {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {p b : Nat} {regs_p : Nat → BitVec 64} {env_p env_b : SymEnv}
    {Bp Bb : Block}
    (hend : SEnd G src si svid facts savail env_p p regs_p) (hhist : SHist G src si svid facts savail o env_p p)
    (hsym : env_p.symAddr = o.symAddr)
    (hBp : src.blocks.val[p]? = some Bp) (hBb : src.blocks.val[b]? = some Bb)
    (hedge : EdgeTaken o regs_p Bp.term (i32n b))
    (hagree : AgreeExcept (i32n b) env_p env_b)
    (hphi : ∀ c k P, idx Bb.phis.val k = some P → env_b.phiVal c (i32n b) k = phiValAt o regs_p p P) :
    ∀ (k : Nat) (P : Phi), Bb.phis.val[k]? = some P → ∀ v, svid[P.dst.val.toNat]? = some v →
      evI G env_b v = phiValAt o regs_p p P := by
  have hlen := C.wf.len_le
  have hbl : b < src.blocks.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hBb; cases hBb
  have hpl : p < src.blocks.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hBp; cases hBp
  have hbn : (i32n b).val.toNat = b := i32n_toNat (by omega)
  have hpn : (i32n p).val.toNat = p := i32n_toNat (by omega)
  have hbv : (i32n b).val = b := i32n_val (by omega)
  have hpv : (i32n p).val = p := i32n_val (by omega)
  obtain ⟨hreach, hfacts, Bp', hBp', hregs⟩ := hend
  rw [hBp] at hBp'; cases hBp'
  have hblk := C.block p Bp hreach hBp
  obtain ⟨-, -, hterm, hsuccs⟩ := hblk
  obtain ⟨-, -, -, S, hS, harmsAv⟩ := hsuccs (i32n b) (edgeTaken_mem hedge)
  rw [hbn, hBb] at hS; cases hS
  have hag : ∀ a, AvailAtom (CurAt si.nt.val.toNat (AvB savail si.nt p) Bp Bp.insts.val.length) a →
      AtomAgree G env_p svid o regs_p a := fun a ha => agree_of_avail hregs hsym ha
  -- the edge is run
  have hruns : RunsEdge G src si svid facts (i32n p) (i32n b) o regs_p env_p := by
    refine ⟨by omega, by rw [hpv, C.info.nb]; omega, by rw [hpn]; exact hreach,
      fun fb hfb he => hfacts fb hfb (by rw [he, hpv]), Bp, by rw [hpn]; exact hBp,
      condAgree_of_avail hregs hsym hterm, hedge⟩
  intro k
  induction k using Nat.strong_induction_on with
  | _ k ih =>
  intro P hP v hv
  have hPm : P ∈ Bb.phis.val := List.mem_of_getElem? hP
  have hkl : k < Bb.phis.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hP; cases hP
  obtain ⟨a, ha, haAv⟩ := harmsAv P hPm
  obtain ⟨A, hA, hAp, hAv⟩ := phiArg_mem ha
  have hApred : A.pred = i32n p := i32_ext (by rw [hAp, hpv])
  have hval : phiValAt o regs_p p P = atomVal o regs_p P.cls a := by simp [phiValAt, ha]
  rw [hval]
  obtain ⟨⟨hpl2, -⟩, hdefs, -⟩ := C.defs (i32n b) (by omega) Bb (by rw [hbn]; exact hBb)
  have hkn : (i32n k).val.toNat = k := i32n_toNat (by omega)
  obtain ⟨hd0, v', hv', hdef⟩ := hdefs (i32n k) P (by rw [i32n_val (by omega)]; omega) (by rw [hkn]; exact hP)
  rw [hv] at hv'; cases hv'
  have hidx : idx Bb.phis.val (i32n k) = some P := by
    unfold idx
    rw [ite_eq_left (by rw [i32n_val (by omega)]; omega), hkn]
    exact hP
  obtain ⟨hvalid, hcase⟩ := hdef
  rcases hcase with hleaf | ⟨hst, hmask, hfarms⟩ | hsel | ⟨k1, hk1, P1, hP1, hcls, hv1, hd1, hsame⟩
  · -- the phi's own leaf
    rw [evI_node C.dag env_b hleaf]
    simp only [evalNode]
    rw [hphi P.cls (i32n k) P hidx, ← hval, phiValAt_masked]
  · -- a folded value
    have hstb : evI G env_b v = evI G env_p v := hst env_p env_b hagree
    rcases hfarms A hA with hself | hdead | ⟨-, -, hk, heq⟩
    · rw [hAv] at hself
      subst hself
      have hd : regs_p P.dst.val.toNat = evI G env_p v := hregs _ haAv.2 v hv hvalid
      rw [hstb, ← hmask env_p]
      simp only [atomVal, atomRaw, hd]
    · exact (hdead G (vg_extends_refl _) o regs_p env_p (by rw [hApred]; exact hruns)).elim
    · rw [hstb, heq env_p, hAv, atomVal_eq (hAv ▸ hk) (hag a haAv)]
  · -- a 0/1 select
    obtain ⟨p1, p0, d, cond, hne, hsarms, hd0', hs1, hs0, ⟨Bd, hBd, hBdt⟩, hck, -, hselv, hsst⟩ := hsel
    have hdl : d.val.toNat < src.blocks.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hBd; cases hBd
    have hp1s : p1 ∈ termSuccs Bd.term := by rw [hBdt]; simp [termSuccs]
    have hp0s : p0 ∈ termSuccs Bd.term := by rw [hBdt]; simp [termSuccs]
    have hp1pos := (C.wf.succ_ok _ Bd hBd p1 hp1s).1
    have hp0pos := (C.wf.succ_ok _ Bd hBd p0 hp0s).1
    -- the run came to `p` from `d`, through the edge to `p`
    have hfrom : ∀ q, A.pred = q → (q = p1 ∨ q = p0) →
        ∃ regs_d env_d, SEnd G src si svid facts savail env_d d.val.toNat regs_d ∧
          EdgeTaken o regs_d Bd.term q ∧ AgreeExcept q env_d env_p := by
      intro q hq hq'
      rcases hhist with h0 | ⟨d', regs_d, env_d, Bd', hendd, hBd', hedged, hagd⟩
      · exfalso
        have : q.val = 0 := by rw [← hq, hApred, hpv, h0]; simp
        rcases hq' with rfl | rfl <;> omega
      · have hqp : i32n p = q := by rw [← hq, hApred]
        rw [hqp] at hedged hagd
        have hdd : d' = d.val.toNat := by
          rcases hq' with rfl | rfl
          · exact hs1 d' Bd' hBd' (edgeTaken_mem hedged)
          · exact hs0 d' Bd' hBd' (edgeTaken_mem hedged)
        subst hdd
        rw [hBd] at hBd'; cases hBd'
        exact ⟨regs_d, env_d, hendd, hedged, hagd⟩
    have hcond : ∀ regs_d env_d, SEnd G src si svid facts savail env_d d.val.toNat regs_d →
        env_d.symAddr = o.symAddr →
        atomVal o regs_d .W cond = maskC .W (atomSem G env_d svid cond) := by
      intro regs_d env_d hendd hsymd
      obtain ⟨hrd, -, Bd', hBd', hregd⟩ := hendd
      rw [hBd] at hBd'; cases hBd'
      obtain ⟨-, -, htd, -⟩ := C.block _ Bd hrd hBd
      rw [hBdt] at htd
      exact atomVal_eq hck (agree_of_avail hregd hsymd htd) .W
    have hstb : evI G env_b v = evI G env_p v := hsst (i32n b) (Or.inl rfl) env_p env_b hagree
    rcases hsarms A hA with ⟨hq, hk, h1⟩ | ⟨hq, hk, h0⟩
    · obtain ⟨regs_d, env_d, hendd, hedged, hagd⟩ := hfrom p1 hq (Or.inl rfl)
      have hsymd : env_d.symAddr = o.symAddr := by rw [← hsym, hagd.2.1]
      rw [hBdt] at hedged
      simp only [EdgeTaken] at hedged
      have hc : atomVal o regs_d .W cond ≠ 0 := by
        intro hc; rw [ite_eq_right (by simpa using hc)] at hedged; exact hne hedged
      rw [hstb, hsst p1 (Or.inr (Or.inl rfl)) env_d env_p hagd, hselv env_d, ← hcond regs_d env_d hendd hsymd,
        ite_eq_right hc, ← hAv, atomVal_eq hk (hag _ (hAv ▸ haAv)), h1 env_p]
    · obtain ⟨regs_d, env_d, hendd, hedged, hagd⟩ := hfrom p0 hq (Or.inr rfl)
      have hsymd : env_d.symAddr = o.symAddr := by rw [← hsym, hagd.2.1]
      rw [hBdt] at hedged
      simp only [EdgeTaken] at hedged
      have hc : atomVal o regs_d .W cond = 0 := by
        by_contra hc; rw [ite_eq_left hc] at hedged; exact hne hedged.symm
      rw [hstb, hsst p0 (Or.inr (Or.inr rfl)) env_d env_p hagd, hselv env_d, ← hcond regs_d env_d hendd hsymd,
        ite_eq_left hc, ← hAv, atomVal_eq hk (hag _ (hAv ▸ haAv)), h0 env_p]
  · -- an earlier phi with the same arguments
    have hP1m : P1 ∈ Bb.phis.val := List.mem_of_getElem? hP1
    rw [ih k1 (by rw [hkn] at hk1; exact hk1) P1 hP1 v hv1]
    obtain ⟨a1, ha1, hcase⟩ := hsame A hA
    rw [hAp] at ha1
    have hval1 : phiValAt o regs_p p P1 = atomVal o regs_p P.cls a1 := by
      simp [phiValAt, ha1, hcls]
    rw [hval1]
    obtain ⟨a1', ha1', ha1Av⟩ := harmsAv P1 hP1m
    rw [ha1] at ha1'; cases ha1'
    rcases hcase with ⟨hs1, hs2⟩ | ⟨hk1', hk2', heq⟩
    · rw [hAv] at hs2
      subst hs1 hs2
      have e1 : regs_p P1.dst.val.toNat = evI G env_p v := hregs _ ha1Av.2 v hv1 hvalid
      have e2 : regs_p P.dst.val.toNat = evI G env_p v := hregs _ haAv.2 v hv hvalid
      simp only [atomVal, atomRaw, e1, e2]
    · rw [atomVal_eq hk1' (hag _ ha1Av), ← hAv, atomVal_eq hk2' (hag _ (hAv ▸ haAv)), heq env_p]

/-! ## Instructions -/

theorem execInsts_append {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) :
    ∀ (l1 l2 : List Inst) (s : MState W),
      execInsts o args (l1 ++ l2) s = (execInsts o args l1 s).bind (execInsts o args l2)
  | [], l2, s => by simp [execInsts]
  | i :: l1, l2, s => by
    simp only [List.cons_append, execInsts, Option.bind_assoc]
    congr 1
    funext s'
    exact execInsts_append o args l1 l2 s'

theorem execInsts_take_succ {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) {l : List Inst}
    {x : Nat} (hx : x < l.length) {s0 s s' : MState W} (h0 : execInsts o args (l.take x) s0 = some s)
    (h1 : execInst o args s l[x] = some s') : execInsts o args (l.take (x + 1)) s0 = some s' := by
  rw [List.take_add_one, List.getElem?_eq_getElem hx, Option.toList_some, execInsts_append, h0]
  simp [execInsts, h1]

/-- An instruction writes at most its destination. -/
theorem execInst_regs {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {s s' : MState W}
    {inst : Inst} {nt : Std.I32} (hd : DstOK nt inst) (h : execInst o args s inst = some s') (t : Nat)
    (ht : (instDst inst).val.toNat ≠ t ∨ (instDst inst).val < 0) : s'.regs t = s.regs t := by
  have key : ∀ (d : Std.I32) v, 0 ≤ d.val → (d.val.toNat ≠ t ∨ d.val < 0) → setReg s.regs d v t = s.regs t := by
    intro d v hd0 ht'
    simp only [setReg]
    rw [ite_eq_right]
    rcases ht' with h1 | h1
    · exact fun e => h1 e.symm
    · omega
  cases inst with
  | Par d c k =>
    simp only [execInst, Option.some.injEq] at h; subst h; exact key d _ hd.1 ht
  | Un d c op a =>
    simp only [execInst, Option.some.injEq] at h; subst h; exact key d _ hd.1 ht
  | Bin d c op a b =>
    simp only [execInst] at h
    cases hx : evalBin c op (atomVal o s.regs (binArgCls op c 0) a) (atomVal o s.regs (binArgCls op c 1) b) with
    | none => rw [hx] at h; simp at h
    | some v => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; exact key d v hd.1 ht
  | Load d c w sg a =>
    simp only [execInst] at h
    cases hx : o.load s.world w sg (atomVal o s.regs .L a) with
    | none => rw [hx] at h; simp at h
    | some v => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; exact key d _ hd.1 ht
  | Store w v a =>
    simp only [execInst] at h
    cases hx : o.store s.world w (maskWidth w (atomVal o s.regs (storeCls w) v)) (atomVal o s.regs .L a) with
    | none => rw [hx] at h; simp at h
    | some w' => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; rfl
  | Call d c hh cal cargs =>
    simp only [execInst] at h
    cases hx : o.call s.world (atomVal o s.regs .L cal) (cargs.val.map fun ca => (ca.cls, atomVal o s.regs ca.cls ca.arg)) with
    | none => rw [hx] at h; simp at h
    | some p =>
      rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h
      cases hh
      · rfl
      · exact key d _ (hd rfl).1 (by simpa [instDst] using ht)
  | Alloc d al sz =>
    simp only [execInst] at h
    cases hx : o.alloc s.world al sz with
    | none => rw [hx] at h; simp at h
    | some p => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; exact key d _ hd.1 ht

/-- A leaf instruction writes a value kept at its effect class. -/
theorem instVal_masked {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {s s' : MState W}
    {inst : Inst} (hl : LeafInst inst) (hd0 : 0 ≤ (instDst inst).val) (h : execInst o args s inst = some s') :
    maskC (effCls inst) (s'.regs (instDst inst).val.toNat) = s'.regs (instDst inst).val.toNat := by
  cases inst with
  | Bin d c op a b =>
    simp only [execInst] at h
    cases hx : evalBin c op (atomVal o s.regs (binArgCls op c 0) a) (atomVal o s.regs (binArgCls op c 1) b) with
    | none => rw [hx] at h; simp at h
    | some v =>
      rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h
      simp only [instDst, effCls, setReg, ↓reduceIte]
      exact evalBin_masked hx
  | Load d c w sg a =>
    simp only [execInst] at h
    cases hx : o.load s.world w sg (atomVal o s.regs .L a) with
    | none => rw [hx] at h; simp at h
    | some v =>
      rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h
      simp only [instDst, effCls, setReg, ↓reduceIte]
      exact maskC_idem _ _
  | Call d c hh cal cargs =>
    simp only [execInst] at h
    cases hx : o.call s.world (atomVal o s.regs .L cal) (cargs.val.map fun ca => (ca.cls, atomVal o s.regs ca.cls ca.arg)) with
    | none => rw [hx] at h; simp at h
    | some p =>
      rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h
      cases hh
      · simp [instDst] at hd0
      · simp only [instDst, effCls, setReg, ↓reduceIte]
        exact maskC_idem _ _
  | Alloc d al sz => rfl
  | _ => exact absurd hl (by simp [LeafInst])

theorem opsAgree_of_avail {W : Type} {G : ValGraph} {env : SymEnv} {svid : List Std.I32}
    {o : WorldOracle W} {regs : Nat → BitVec 64} {cur : Nat → Prop} (hag : RegsAgree G env cur svid regs)
    (hsym : env.symAddr = o.symAddr) {inst : Inst} (ha : AvailInst cur inst) :
    OpsAgree G env svid o regs inst := by
  cases inst with
  | Par _ _ _ => trivial
  | Un _ _ _ a => exact agree_of_avail hag hsym ha
  | Bin _ _ _ a b => exact ⟨agree_of_avail hag hsym ha.1, agree_of_avail hag hsym ha.2⟩
  | Load _ _ _ _ a => exact agree_of_avail hag hsym ha
  | Store _ v a => exact ⟨agree_of_avail hag hsym ha.1, agree_of_avail hag hsym ha.2⟩
  | Call _ _ _ c args => exact ⟨agree_of_avail hag hsym ha.1, fun x hx => agree_of_avail hag hsym (ha.2 x hx)⟩
  | Alloc _ _ _ => trivial

/-- The source inside block `b` (`B`), after its phis (state `s0`) and its first `x` instructions
(state `s`), in environment `env`. -/
structure SIn (G : ValGraph) (src : Func) (si : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (savail : Pion.Array Bool) {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (env : SymEnv)
    (b : Nat) (B : Block) (s0 s : MState W) (x : Nat) : Prop where
  reach : si.reach.val[b]? = some true
  blk : src.blocks.val[b]? = some B
  le : x ≤ B.insts.val.length
  facts : ∀ fa ∈ facts, fa.blk.val = b → FactOK G env fa
  regs : RegsAgree G env (CurAt si.nt.val.toNat (AvB savail si.nt b) B x) svid s.regs
  run : execInsts o args (B.insts.val.take x) s0 = some s
  la : ∀ c (i : Nat) inst, x ≤ i → B.insts.val[i]? = some inst → leafB inst = true →
    env.effVal c (i32n b) (i32n i) = effAt o args B s0 i
  sym : env.symAddr = o.symAddr
  par : ∀ c k, env.paramVal c k = argVal args k

theorem sIn_end {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv}
    {b : Nat} {B : Block} {s0 s : MState W}
    (h : SIn G src si svid facts savail o args env b B s0 s B.insts.val.length) :
    SEnd G src si svid facts savail env b s.regs :=
  ⟨h.reach, h.facts, B, h.blk, h.regs⟩

/-- One instruction of the source. -/
theorem src_inst_step {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {env : SymEnv}
    {b : Nat} {B : Block} {s0 s s' : MState W} {x : Nat}
    (hin : SIn G src si svid facts savail o args env b B s0 s x) (hx : x < B.insts.val.length)
    (h : execInst o args s B.insts.val[x] = some s') :
    SIn G src si svid facts savail o args env b B s0 s' (x + 1) := by
  have hlen := C.wf.len_le
  have hblk := hin.blk
  have hbl : b < src.blocks.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hblk; cases hblk
  obtain ⟨⟨-, hil⟩, -, hidefs⟩ := C.defs (i32n b) (by rw [i32n_val (by omega)]; omega) B
    (by rw [i32n_toNat (by omega)]; exact hblk)
  have hxn : (i32n x).val.toNat = x := i32n_toNat (by omega)
  have hx0 : 0 ≤ (i32n x).val := by rw [i32n_val (by omega)]; omega
  obtain ⟨-, hinsts, -, -⟩ := C.block b B hin.reach hblk
  obtain ⟨havail, -⟩ := hinsts x hx
  have hdst := C.wf.dsts b B hblk B.insts.val[x] (List.getElem_mem _)
  refine ⟨hin.reach, hblk, by omega, hin.facts, ?_, execInsts_take_succ o args hx hin.run h,
    fun c i inst hi hii hl => hin.la c i inst (by omega) hii hl, hin.sym, hin.par⟩
  intro t ht v hv hvv
  by_cases hdt : 0 ≤ (instDst B.insts.val[x]).val ∧ (instDst B.insts.val[x]).val.toNat = t
  · obtain ⟨hd0, rfl⟩ := hdt
    obtain ⟨v', hv', hvv', hcase⟩ := hidefs (i32n x) hx0 (by rw [hxn]; exact hx) (by simpa [hxn] using hd0)
    simp only [hxn] at hv' hcase
    rw [hv] at hv'; cases hv'
    rcases hcase with hpd | ⟨hli, hnode⟩
    · have hops := opsAgree_of_avail hin.regs hin.sym havail
      rw [pureDef_exec hpd o args env s ⟨hin.sym, hin.par⟩ hops] at h
      cases h
      simp [setReg]
    · rw [evI_node C.dag env hnode]
      simp only [evalNode]
      rw [hin.la _ x _ (le_refl _) (List.getElem?_eq_getElem hx) ((leafB_iff _).2 hli)]
      simp only [effAt, hin.run, List.getElem?_eq_getElem hx, instVal, h]
      exact (instVal_masked hli hd0 h).symm
  · have ht' : (instDst B.insts.val[x]).val.toNat ≠ t ∨ (instDst B.insts.val[x]).val < 0 := by
      by_cases h0 : 0 ≤ (instDst B.insts.val[x]).val
      · exact Or.inl (fun e => hdt ⟨h0, e⟩)
      · exact Or.inr (by omega)
    rw [execInst_regs hdst h t ht']
    refine hin.regs t ⟨ht.1, ?_⟩ v hv hvv
    rcases ht.2 with h1 | h1 | ⟨k, hk, hkl, hkd⟩
    · exact Or.inl h1
    · exact Or.inr (Or.inl h1)
    · right; right
      by_cases hkx : k = x
      · subst hkx
        exfalso; apply hdt
        exact ⟨by omega, by omega⟩
      · exact ⟨k, by omega, hkl, hkd⟩

/-- Entering block `b` from `p`: the phis, the environment of this visit, the facts of `b`. -/
theorem src_enter {G : ValGraph} {src : Func} {si : FnInfo} {svid : List Std.I32} {facts : List Fact}
    {savail : Pion.Array Bool} (C : SrcCtx G src si svid facts savail)
    {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {p b : Nat} {regs_p R : Nat → BitVec 64}
    {env_p : SymEnv} {Bp Bb : Block} (w : W)
    (hend : SEnd G src si svid facts savail env_p p regs_p) (hhist : SHist G src si svid facts savail o env_p p)
    (hsym : env_p.symAddr = o.symAddr) (hpar : ∀ c k, env_p.paramVal c k = argVal args k)
    (hBp : src.blocks.val[p]? = some Bp) (hBb : src.blocks.val[b]? = some Bb)
    (hedge : EdgeTaken o regs_p Bp.term (i32n b))
    (hphis : execPhis o regs_p p Bb.phis.val regs_p = some R) :
    SIn G src si svid facts savail o args
        (enterEnv o args env_p (i32n b) Bb p regs_p { regs := R, world := w }) b Bb
        { regs := R, world := w } { regs := R, world := w } 0 ∧
      SHist G src si svid facts savail o
        (enterEnv o args env_p (i32n b) Bb p regs_p { regs := R, world := w }) b := by
  have hlen := C.wf.len_le
  have hbl : b < src.blocks.val.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at hBb; cases hBb
  have hbn : (i32n b).val.toNat = b := i32n_toNat (by omega)
  have hbv : (i32n b).val = b := i32n_val (by omega)
  have hag := enterEnv_agree o args env_p (i32n b) Bb p regs_p { regs := R, world := w }
  obtain ⟨hreachp, hfactsp, Bp', hBp', hregsp⟩ := hend
  rw [hBp] at hBp'; cases hBp'
  have hbs : i32n b ∈ termSuccs Bp.term := edgeTaken_mem hedge
  have hreach : si.reach.val[b]? = some true := by
    have := C.info.closed p Bp hBp hreachp (i32n b) hbs (by omega) (by omega)
    rwa [hbn] at this
  obtain ⟨-, -, htermp, hsuccp⟩ := C.block p Bp hreachp hBp
  obtain ⟨-, -, hav, -⟩ := hsuccp (i32n b) hbs
  obtain ⟨⟨-, hil⟩, -, -⟩ := C.defs (i32n b) (by omega) Bb (by rw [hbn]; exact hBb)
  obtain ⟨-, hphiR⟩ := execPhis_spec o regs_p p Bb.phis.val regs_p R hphis
  refine ⟨⟨hreach, hBb, by omega, fun fa hfa hfb => ?_, fun t ht v hv hvv => ?_, rfl, ?_, hsym, hpar⟩,
    Or.inr ⟨p, regs_p, env_p, Bp, ⟨hreachp, hfactsp, Bp, hBp, hregsp⟩, hBp, hedge, hag⟩⟩
  · -- the facts of `b`
    have hfb' : fa.blk = i32n b := i32_ext (by rw [hfb, hbv])
    obtain ⟨-, -, -, -, hst, himp⟩ := C.facts fa hfa
    have hok := himp p Bp hreachp hBp (by rw [hfb']; exact hbs) o regs_p env_p
      (condAgree_of_avail hregsp hsym htermp) (by rw [hfb']; exact hedge) hfactsp
    obtain ⟨hv, hz, hnz⟩ := hok
    have e := hst env_p _ (by rw [hfb']; exact hag)
    exact ⟨hv, fun h => by rw [e]; exact hz h, fun h => by rw [e]; exact hnz h⟩
  · -- the registers
    by_cases hex : ∃ P ∈ Bb.phis.val, P.dst.val.toNat = t
    · obtain ⟨P', hP', hd', a', ha', hR⟩ := (hphiR t).2 hex
      obtain ⟨k, hk, hkP⟩ := List.getElem_of_mem hP'
      subst hd'
      have := src_phi_sem C ⟨hreachp, hfactsp, Bp, hBp, hregsp⟩ hhist hsym hBp hBb hedge hag
        (fun c k P hk => enterEnv_phi o args env_p (i32n b) Bb p regs_p _ c k P hk) k P'
        (by rw [List.getElem?_eq_getElem hk, hkP]) v hv
      rw [this]
      simp only [hR, phiValAt, ha']
    · push Not at hex
      show R t = _
      rw [(hphiR t).1 hex]
      obtain ⟨htn, hcase⟩ := ht
      have havb : AvB savail si.nt b t := by
        rcases hcase with h1 | ⟨P, hP, hPd⟩ | ⟨k, hk, -⟩
        · exact h1
        · exact absurd (by omega) (hex P hP)
        · omega
      rw [hregsp t (by rw [← hbn] at havb; exact hav t htn havb) v hv hvv]
      exact (C.scope b hreach hbl t htn havb v hv hvv.1 env_p _ hag).symm
  · -- the leaves of the instructions
    intro c i inst _ hii hl
    have hil' : i < Bb.insts.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hii; cases hii
    have hidx : idx Bb.insts.val (i32n i) = some inst := by
      unfold idx
      rw [ite_eq_left (by rw [i32n_val (by omega)]; omega), i32n_toNat (by omega)]
      exact hii
    rw [enterEnv_eff o args env_p (i32n b) Bb p regs_p _ c (i32n i) inst hidx hl, i32n_toNat (by omega)]

end PionProofs.QbeTvP
