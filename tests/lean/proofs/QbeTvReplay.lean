/-
The definition checks and the replay of `verify_cert` (`tools/qbe_tv/src/validate.pion`)
as properties of the value graph, for the simulation proof of `QbeTvProofs`:

- `eval_inst_sound`, `check_src_defs_sound`, `check_tgt_defs_sound`: the symbolic value of
  every defined temp is the value of its definition (a phi: its leaf, its folded value
  over its live edges, its 0/1 select, or an earlier phi with the same arguments);
- the replay of a certified pair (`replay_pair`) and its terminator check (`check_end`).
-/
import PionProofs.QbeTvFacts
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Values of instructions -/

/-- The temp of an atom has a known value. -/
def AtomKnown (G : ValGraph) (vids : List Std.I32) (a : Atom) : Prop :=
  ∀ t, a = .Temp t → 0 ≤ t.val ∧ ∃ w, vids[t.val.toNat]? = some w ∧ Valid G w

theorem atomKnown_extends {G G' : ValGraph} (hp : vg_extends G G') {vids : List Std.I32} {a : Atom}
    (h : AtomKnown G vids a) : AtomKnown G' vids a := by
  intro t ht
  obtain ⟨h0, w, hw, hv⟩ := h t ht
  exact ⟨h0, w, hw, extends_valid hp hv⟩

theorem atomSem_extends {G G' : ValGraph} (hp : vg_extends G G') {vids : List Std.I32} {a : Atom}
    (h : AtomKnown G vids a) (env : SymEnv) : atomSem G' env vids a = atomSem G env vids a := by
  cases a with
  | Temp t =>
    obtain ⟨h0, w, hw, hv⟩ := h t rfl
    simp only [atomSem, h0, ↓reduceIte, hw, extends_evI hp env hv]
  | _ => rfl

/-- The class of the effect leaf of an instruction (`eval_inst`). -/
def effCls : Inst → Cls
  | .Alloc _ _ _ => .L
  | .Par _ c _ => c
  | .Un _ c _ _ => c
  | .Bin _ c _ _ _ => c
  | .Load _ c _ _ _ => c
  | .Call _ c _ _ _ => c
  | .Store _ _ _ => .L

/-- Instructions whose value may be a leaf `SEffect` of the value graph. -/
def LeafInst : Inst → Prop
  | .Bin _ _ op _ _ => trapOp op = true
  | .Load _ _ _ _ _ => True
  | .Call _ _ _ _ _ => True
  | .Alloc _ _ _ => True
  | _ => False

theorem bind_id_ok {α : Type} {m : Result α} {r : α} (h : (do let x ← m; ok x) = ok r) : m = ok r := by
  obtain ⟨a, ha, e⟩ := bind_eq_ok h
  rw [ha, ok_inj' e]

/-- `v` is the value of the pure instruction `inst` in every environment. -/
def PureDef (G : ValGraph) (vids : List Std.I32) (inst : Inst) (v : Std.I32) : Prop :=
  match inst with
  | .Par _ c k => ∀ env, evI G env v = maskC c (env.paramVal c k)
  | .Un _ c op a => AtomKnown G vids a ∧
      ∀ env, evI G env v = evalUn c op (maskC (unArgCls op c) (atomSem G env vids a))
  | .Bin _ c op a b => AtomKnown G vids a ∧ AtomKnown G vids b ∧
      ∀ env, evalBin c op (maskC (binArgCls op c 0) (atomSem G env vids a))
        (maskC (binArgCls op c 1) (atomSem G env vids b)) = some (evI G env v)
  | _ => False

theorem pureDef_extends {G G' : ValGraph} (hp : vg_extends G G') {vids : List Std.I32} {inst : Inst}
    {v : Std.I32} (hv : Valid G v) (h : PureDef G vids inst v) : PureDef G' vids inst v := by
  cases inst with
  | Par d c k => intro env; rw [extends_evI hp env hv]; exact h env
  | Un d c op a =>
    refine ⟨atomKnown_extends hp h.1, fun env => ?_⟩
    rw [extends_evI hp env hv, atomSem_extends hp h.1]; exact h.2 env
  | Bin d c op a b =>
    refine ⟨atomKnown_extends hp h.1, atomKnown_extends hp h.2.1, fun env => ?_⟩
    rw [extends_evI hp env hv, atomSem_extends hp h.1, atomSem_extends hp h.2.1]; exact h.2.2 env
  | _ => exact h

theorem vg_canon_un_invalid {vg : ValGraph} {cls : Cls} {op : UnOp} {a : Std.I32}
    {p : Std.I32 × ValGraph} (h : vg_canon_un vg cls op a = ok p) (hv : ¬ Valid vg a) :
    p = ((-1)#i32, vg) := by
  rw [vg_canon_un] at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, -⟩ := vg_valid_ok ht
  have : t = false := by
    cases t
    · rfl
    · exact absurd (ht1.1 rfl) hv
  subst this
  simp only [Bool.not_false, ↓reduceIte] at h
  exact (ok_inj' h).symm

theorem vg_canon_bin_invalid {vg : ValGraph} {cls : Cls} {op : BinOp} {a b : Std.I32}
    {p : Std.I32 × ValGraph} (h : vg_canon_bin vg cls op a b = ok p) (hv : ¬ (Valid vg a ∧ Valid vg b)) :
    p = ((-1)#i32, vg) := by
  rw [vg_canon_bin] at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, -⟩ := vg_valid_ok ht
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  have h2 : t2 = true := by
    cases t
    · cases ok_inj' ht2; rfl
    · simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at ht2
      obtain ⟨t1, ht1', ht2⟩ := bind_eq_ok ht2
      obtain ⟨ht11, -⟩ := vg_valid_ok ht1'
      cases ok_inj' ht2
      cases t1
      · rfl
      · exact absurd ⟨ht1.1 rfl, ht11.1 rfl⟩ hv
  subst h2
  simp only [↓reduceIte] at h
  exact (ok_inj' h).symm

/-- What `eval_inst` gives: a pure value, or the instruction's own effect leaf. -/
theorem eval_inst_sound {vg : ValGraph} {vids : Pion.Array Std.I32} {inst : Inst} {b i : Std.I32}
    {leaf : Bool} {p : Std.I32 × ValGraph} (h : eval_inst vg vids inst b i leaf = ok p)
    (hd : ValGraphDAG vg) (hv : VidsOK vg vids.val) :
    vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧
      (0 ≤ p.1.val → Valid p.2 p.1 ∧ (PureDef p.2 vids.val inst p.1 ∨
        (leaf = true ∧ LeafInst inst ∧ nodeAt p.2 p.1 = some (.SEffect (effCls inst) b i)))) := by
  have heff : ∀ (vg' : ValGraph) c q, vg_extends vg vg' → ValGraphDAG vg' →
      vg_intern vg' (.SEffect c b i) = ok q → effCls inst = c → leaf = true → LeafInst inst →
      vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
        (0 ≤ q.1.val → Valid q.2 q.1 ∧ (PureDef q.2 vids.val inst q.1 ∨
          (leaf = true ∧ LeafInst inst ∧ nodeAt q.2 q.1 = some (.SEffect (effCls inst) b i)))) := by
    rintro vg' c ⟨r, vg''⟩ e' d' hq hc hl hli
    obtain ⟨e, d, n, -, -⟩ := vg_intern_spec hq d' trivial
    exact ⟨vg_extends_trans e' e, d, fun _ => ⟨nodeAt_valid n, Or.inr ⟨hl, hli, by rw [hc]; exact n⟩⟩⟩
  have hneg : ∀ vg' : ValGraph, vg_extends vg vg' → ValGraphDAG vg' → p = ((-1)#i32, vg') →
      vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧
        (0 ≤ p.1.val → Valid p.2 p.1 ∧ (PureDef p.2 vids.val inst p.1 ∨
          (leaf = true ∧ LeafInst inst ∧ nodeAt p.2 p.1 = some (.SEffect (effCls inst) b i)))) := by
    rintro vg' e d rfl
    exact ⟨e, d, fun hc => absurd hc (by simp only; exact not_le.2 m1_neg)⟩
  unfold eval_inst at h
  cases inst with
  | Par d c k =>
    simp only at h
    obtain ⟨e, dd, n, -, val⟩ := vg_intern_spec (pair_ok h) hd trivial
    exact ⟨e, dd, fun _ => ⟨nodeAt_valid n, Or.inl (fun env => by rw [val env]; rfl)⟩⟩
  | Un d c op a =>
    simp only [unop_arg_cls_spec, bind_ok] at h
    obtain ⟨q, hq, h⟩ := bind_eq_ok h
    obtain ⟨av, vg2⟩ := q
    try simp only [uncurry_apply_pair] at h
    obtain ⟨e2, d2, h2⟩ := atom_use_sound hq hd hv
    dsimp only at e2 d2 h2
    by_cases hav : 0 ≤ av.val
    · obtain ⟨v2, c2, hk2, val2⟩ := h2 hav
      obtain ⟨e3, d3, v3, -, val3⟩ := vg_canon_un_sound vg2 c op d2 av p (pair_ok h) v2
        ⟨fun e => by subst e; simpa [unArgCls] using c2,
          fun _ e => by rcases e with rfl | rfl <;> simpa [unArgCls] using c2⟩
      refine ⟨vg_extends_trans e2 e3, d3, fun _ => ⟨v3, Or.inl ⟨?_, fun env => ?_⟩⟩⟩
      · intro t ht
        obtain ⟨h0, w, hw, hvw⟩ := hk2 t ht
        exact ⟨h0, w, hw, extends_valid (vg_extends_trans e2 e3) hvw⟩
      · rw [val3 env]; dsimp only; rw [val2 env]
        congr 2
        have hk : AtomKnown vg vids.val a := fun t ht => hk2 t ht
        rw [atomSem_extends (vg_extends_trans e2 e3) hk]
    · have hinv : ¬ Valid vg2 av := fun hc => hav hc.1
      exact hneg vg2 e2 d2 (vg_canon_un_invalid (pair_ok h) hinv)
  | Bin d c op a x =>
    simp only [binop_arg_cls_spec0, binop_arg_cls_spec1, is_trapping_binop_spec, bind_ok] at h
    obtain ⟨q4, hq4, h⟩ := bind_eq_ok h
    obtain ⟨av, vg4⟩ := q4
    try simp only [uncurry_apply_pair] at h
    obtain ⟨q5, hq5, h⟩ := bind_eq_ok h
    obtain ⟨bv, vg5⟩ := q5
    try simp only [uncurry_apply_pair] at h
    obtain ⟨e4, d4, h4⟩ := atom_use_sound hq4 hd hv
    obtain ⟨e5, d5, h5⟩ := atom_use_sound hq5 d4 (vidsOK_extends e4 hv)
    dsimp only at e4 d4 h4 e5 d5 h5
    obtain ⟨t16, ht16, h⟩ := bind_eq_ok h
    split at h
    · rename_i h16t
      have htr : trapOp op = true := by
        cases htr : trapOp op
        · rw [htr] at ht16
          simp only [Bool.false_eq_true, ↓reduceIte] at ht16
          cases ok_inj' ht16
          exact absurd h16t (by simp)
        · rfl
      split at h
      · rename_i hl
        exact heff vg5 c p (vg_extends_trans e4 e5) d5 (pair_ok h) rfl hl htr
      · exact hneg vg5 (vg_extends_trans e4 e5) d5 (ok_inj' h).symm
    · rename_i h16
      by_cases hab : 0 ≤ av.val ∧ 0 ≤ bv.val
      · obtain ⟨va, ca, hka, vala⟩ := h4 hab.1
        obtain ⟨vb, cb, hkb, valb⟩ := h5 hab.2
        have ca' : clsOf vg5 av = binArgCls op c 0 := by rw [extends_clsOf e5 va]; exact ca
        have hok : BinArgOK vg5 c op av bv := by
          unfold BinArgOK
          cases op <;> simp [isCmp, isShift, binArgCls] at ca' cb ⊢ <;>
            first | exact ⟨ca', cb⟩ | exact ca'
        obtain ⟨e7, d7, v7, -, val7⟩ := vg_canon_bin_sound (pair_ok h) d5 (extends_valid e5 va) vb hok
        have hsafe : ∀ env, evalBin c op (evI vg5 env av) (evI vg5 env bv) ≠ none := by
          intro env
          cases htr : trapOp op
          · exact evalBin_some_of_not_trap htr c _ _
          · rw [htr] at ht16
            simp only [↓reduceIte] at ht16
            obtain ⟨t15, ht15, ht16⟩ := bind_eq_ok ht16
            cases ok_inj' ht16
            have : t15 = true := by revert h16; cases t15 <;> decide
            subst this
            exact bin_safe_sound ht15 d5 env
        refine ⟨vg_extends_trans e4 (vg_extends_trans e5 e7), d7, fun _ => ⟨v7, Or.inl ⟨?_, ?_, fun env => ?_⟩⟩⟩
        · exact atomKnown_extends (vg_extends_trans e4 (vg_extends_trans e5 e7)) (fun t ht => hka t ht)
        · exact atomKnown_extends (vg_extends_trans e5 e7) (fun t ht => hkb t ht)
        · obtain ⟨w, hw⟩ := Option.ne_none_iff_exists'.1 (hsafe env)
          rw [val7 env w hw]
          rw [extends_evI e5 env va, vala env, valb env] at hw
          rw [atomSem_extends (vg_extends_trans e4 (vg_extends_trans e5 e7)) (fun t ht => hka t ht),
            atomSem_extends (vg_extends_trans e5 e7) (fun t ht => hkb t ht)]
          exact hw
      · have hinv : ¬ (Valid vg5 av ∧ Valid vg5 bv) := fun hc => hab ⟨hc.1.1, hc.2.1⟩
        exact hneg vg5 (vg_extends_trans e4 e5) d5 (vg_canon_bin_invalid (pair_ok h) hinv)
  | Load d c w sg a =>
    simp only at h
    split at h
    · rename_i hl; exact heff vg c p (vg_extends_refl _) hd (pair_ok h) rfl hl trivial
    · exact hneg vg (vg_extends_refl _) hd (ok_inj' h).symm
  | Call d c hh cal args =>
    simp only at h
    split at h
    · rename_i hl; exact heff vg c p (vg_extends_refl _) hd (pair_ok h) rfl hl trivial
    · exact hneg vg (vg_extends_refl _) hd (ok_inj' h).symm
  | Alloc d al sz =>
    simp only at h
    split at h
    · rename_i hl; exact heff vg .L p (vg_extends_refl _) hd (pair_ok h) rfl hl trivial
    · exact hneg vg (vg_extends_refl _) hd (ok_inj' h).symm
  | Store w v a =>
    simp only at h
    exact hneg vg (vg_extends_refl _) hd (ok_inj' h).symm

/-! ## Running a pure instruction -/

/-- The environment gives the run's symbols and parameters. -/
def EnvOK {W : Type} (o : WorldOracle W) (args : List (BitVec 64)) (env : SymEnv) : Prop :=
  env.symAddr = o.symAddr ∧ ∀ c k, env.paramVal c k = argVal args k

/-- The operands of an instruction agree with `vids`. -/
def OpsAgree {W : Type} (G : ValGraph) (env : SymEnv) (vids : List Std.I32) (o : WorldOracle W)
    (regs : Nat → BitVec 64) : Inst → Prop
  | .Par _ _ _ => True
  | .Un _ _ _ a => AtomAgree G env vids o regs a
  | .Bin _ _ _ a b => AtomAgree G env vids o regs a ∧ AtomAgree G env vids o regs b
  | .Load _ _ _ _ a => AtomAgree G env vids o regs a
  | .Store _ v a => AtomAgree G env vids o regs v ∧ AtomAgree G env vids o regs a
  | .Call _ _ _ c args => AtomAgree G env vids o regs c ∧ ∀ x ∈ args.val, AtomAgree G env vids o regs x.arg
  | .Alloc _ _ _ => True

theorem atomVal_eq {W : Type} {G : ValGraph} {vids : List Std.I32} {a : Atom} {env : SymEnv}
    {o : WorldOracle W} {regs : Nat → BitVec 64} (hk : AtomKnown G vids a)
    (hag : AtomAgree G env vids o regs a) (c : Cls) :
    atomVal o regs c a = maskC c (atomSem G env vids a) := by
  unfold atomVal atomRaw
  congr 1
  cases a with
  | Temp t =>
    obtain ⟨h0, w, hw, hv⟩ := hk t rfl
    simp only [atomSem, h0, ↓reduceIte, hw]
    exact hag.2 t rfl w hw hv
  | Const x => rfl
  | Sym sy off => simp only [atomSem, hag.1]

/-- A pure instruction writes its value to its destination. -/
theorem pureDef_exec {W : Type} {G : ValGraph} {vids : List Std.I32} {inst : Inst} {v : Std.I32}
    (h : PureDef G vids inst v) (o : WorldOracle W) (args : List (BitVec 64)) (env : SymEnv)
    (s : MState W) (henv : EnvOK o args env) (hops : OpsAgree G env vids o s.regs inst) :
    execInst o args s inst = some { s with regs := setReg s.regs (instDst inst) (evI G env v) } := by
  cases inst with
  | Par d c k =>
    simp only [execInst, instDst]
    congr 3
    rw [h env, henv.2]
  | Un d c op a =>
    simp only [execInst, instDst]
    rw [atomVal_eq h.1 hops, h.2 env]
  | Bin d c op a b =>
    simp only [execInst, instDst]
    rw [atomVal_eq h.1 hops.1, atomVal_eq h.2.1 hops.2, h.2.2 env]
    rfl
  | _ => exact absurd h (by simp [PureDef])

/-! ## `vids_ok` -/

theorem vids_ok_sound {vg : ValGraph} {vids : Pion.Array Std.I32} {n : Std.I32}
    (h : vids_ok vg vids n = ok true) : vids.val.length = n.val.toNat ∧ 0 ≤ n.val ∧ VidsOK vg vids.val := by
  unfold vids_ok at h
  obtain ⟨l, hl, h⟩ := bind_eq_ok h
  obtain ⟨hl1, hl2⟩ := arr_length_ok hl
  split at h
  · cases ok_inj' h
  rename_i hln
  have hln' : l.val = n.val := by simpa using hln
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, ht2⟩ := arr_length_ok ht
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun i => vids_ok_loop0.body t vids vg i) vids.val.length
    (fun k => ∀ hk : k < vids.val.length, vids.val[k] = (-1)#i32 ∨ Valid vg vids.val[k])
    (fun _ b => b = false) (fun _ => True)
    (by
      intro i c hi hc
      unfold vids_ok_loop0.body at hc
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, ht1] at hlt
        obtain ⟨v, hv, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hvl, hvv⟩ := arr_get_ok hv
        obtain ⟨t3, ht3, hc⟩ := bind_eq_ok hc
        left
        refine ⟨hlt, ht2, ?_⟩
        split at hc
        · left; exact ⟨false, (ok_inj' hc).symm, rfl⟩
        · rename_i h3
          right
          refine ⟨fun hk => ?_, (ok_inj' hc).symm⟩
          rw [hvv]
          split at ht3
          · rename_i hne
            obtain ⟨t2, ht2', ht3⟩ := bind_eq_ok ht3
            cases ok_inj' ht3
            have : t2 = true := by revert h3; cases t2 <;> decide
            subst this
            exact Or.inr ((vg_valid_ok ht2').1.1 rfl)
          · rename_i heq
            exact Or.inl (i32_ext (by simpa using heq))
      · rename_i hge
        simp only [i32_lt_iff, ht1, not_lt] at hge
        right
        exact ⟨hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b =>
    obtain ⟨_, _, _, hb, _⟩ := hk
    simp only at h
    subst hb
    cases ok_inj' h
  | inr g =>
    refine ⟨by omega, by omega, fun t v htv => ?_⟩
    have htl : t < vids.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at htv; cases htv
    rw [List.getElem?_eq_getElem htl] at htv
    cases htv
    exact hk.2 t (by simp) htl htl

/-! ## `check_tgt_defs` -/

/-- An instruction `check_tgt_defs` checks: `par`, unary, or a binary operator that never traps. -/
def TgtChecked : Inst → Prop
  | .Par _ _ _ => True
  | .Un _ _ _ _ => True
  | .Bin _ _ op _ _ => trapOp op = false
  | _ => False

theorem tgt_effect_c_false {vg : ValGraph} {tvid : Pion.Array Std.I32} {inst : Inst}
    (hc : TgtChecked inst) : tgt_effect_c vg tvid inst = ok (false, vg) := by
  cases inst with
  | Par _ _ _ => rfl
  | Un _ _ _ _ => rfl
  | Bin d c op a b =>
    simp only [TgtChecked] at hc
    simp [tgt_effect_c, is_trapping_binop_spec, hc]
  | _ => exact absurd hc (by simp [TgtChecked])

theorem check_tgt_defs_sound {vg : ValGraph} {f : Func} {info : FnInfo} {tvid : Pion.Array Std.I32}
    {q : Bool × ValGraph} (h : check_tgt_defs vg f info tvid = ok q) (ht : q.1 = true)
    (hd : ValGraphDAG vg) (hinfo : InfoOK f info) (hv : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      ∀ (b : Nat) (B : Block), f.blocks.val[b]? = some B → ∀ i (hi : i < B.insts.val.length), ∀ v,
        0 ≤ (instDst B.insts.val[i]).val → tvid.val[(instDst B.insts.val[i]).val.toNat]? = some v →
        0 ≤ v.val → TgtChecked B.insts.val[i] → Valid q.2 v ∧ PureDef q.2 tvid.val B.insts.val[i] v := by
  have hnb := hinfo.nb
  have hlenle : f.blocks.val.length ≤ 2147483647 := by have := i32_val_le info.nb; omega
  -- what is established, in a graph and its extensions
  let Good : ValGraph → Nat → Prop := fun g (b : Nat) => ∀ (B : Block), f.blocks.val[b]? = some B →
    ∀ i (hi : i < B.insts.val.length), ∀ v,
      0 ≤ (instDst B.insts.val[i]).val → tvid.val[(instDst B.insts.val[i]).val.toNat]? = some v →
      0 ≤ v.val → TgtChecked B.insts.val[i] → Valid g v ∧ PureDef g tvid.val B.insts.val[i] v
  have good_mono : ∀ g g' b, vg_extends g g' → Good g b → Good g' b := by
    intro g g' b e hg B hB i hi v h1 h2 h3 h4
    obtain ⟨hv', hp⟩ := hg B hB i hi v h1 h2 h3 h4
    exact ⟨extends_valid e hv', pureDef_extends e hv' hp⟩
  unfold check_tgt_defs at h
  obtain ⟨s0, hs0, h⟩ := bind_eq_ok h
  unfold check_tgt_defs_loop0 at hs0
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (b, vg) => check_tgt_defs_loop0.body info f tvid b vg)
    (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vg x.2 ∧ ValGraphDAG x.2 ∧
      ∀ b, b < x.1.val.toNat → Good x.2 b)
    (fun r => match r with
      | .inl e => e.1 = false
      | .inr y => vg_extends vg y.2 ∧ ValGraphDAG y.2 ∧ ∀ b, b < f.blocks.val.length → Good y.2 b)
    ?_ _ _ hs0 ⟨by simp, vg_extends_refl _, hd, fun b hb => by simp at hb⟩
  · cases s0 with
    | inl e =>
      simp only at h
      cases ok_inj' h
      simp only at ht key
      rw [ht] at key
      cases key
    | inr y =>
      obtain ⟨b1, vg1⟩ := y
      simp only at h
      cases ok_inj' h
      obtain ⟨e1, d1, hall⟩ := key
      refine ⟨e1, d1, fun b B hB => ?_⟩
      have hb : b < f.blocks.val.length := by
        by_contra hc; rw [List.getElem?_eq_none (by omega)] at hB; cases hB
      exact hall b hb B hB
  rintro ⟨bI, vgb⟩ c ⟨hb0, heb, hdb, hallb⟩ hc
  simp only at hb0 heb hdb hallb hc
  unfold check_tgt_defs_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : bI.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb] using hlt
    have hbs := i32_succ_val' hlt' hlenle
    obtain ⟨B, hB, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
    have hBb : f.blocks.val[bI.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
    obtain ⟨ni, hni, hc⟩ := bind_eq_ok hc
    obtain ⟨hni1, hni2⟩ := arr_length_ok hni
    try simp only at hc
    obtain ⟨s1, hs1, hc⟩ := bind_eq_ok hc
    unfold check_tgt_defs_loop1 at hs1
    have key1 := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
        match x with | (i, vg) => check_tgt_defs_loop1.body ni f bI tvid i vg)
      (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vgb x.2 ∧ ValGraphDAG x.2 ∧
        ∀ i (hi : i < B.insts.val.length), i < x.1.val.toNat → ∀ v,
          0 ≤ (instDst B.insts.val[i]).val → tvid.val[(instDst B.insts.val[i]).val.toNat]? = some v →
          0 ≤ v.val → TgtChecked B.insts.val[i] → Valid x.2 v ∧ PureDef x.2 tvid.val B.insts.val[i] v)
      (fun r => match r with
        | .inl e => e.1 = false
        | .inr y => vg_extends vgb y.2 ∧ ValGraphDAG y.2 ∧
            ∀ i (hi : i < B.insts.val.length), ∀ v,
              0 ≤ (instDst B.insts.val[i]).val → tvid.val[(instDst B.insts.val[i]).val.toNat]? = some v →
              0 ≤ v.val → TgtChecked B.insts.val[i] → Valid y.2 v ∧ PureDef y.2 tvid.val B.insts.val[i] v)
      ?_ _ _ hs1 ⟨by simp, vg_extends_refl _, hdb, fun i hi hi' => by simp at hi'⟩
    · cases s1 with
      | inl e =>
        simp only at hc
        rw [← ok_inj' hc]
        exact key1
      | inr y =>
        obtain ⟨i1, vg1⟩ := y
        simp only at hc
        rw [← ok_inj' hc]
        dsimp only
        obtain ⟨e1, d1, hall1⟩ := key1
        refine ⟨by omega, vg_extends_trans heb e1, d1, fun b hb => ?_⟩
        by_cases hbb : b = bI.val.toNat
        · subst hbb
          intro B' hB'
          rw [hBb] at hB'
          cases hB'
          exact hall1
        · exact good_mono _ _ _ e1 (hallb b (by omega))
    rintro ⟨iI, vgi⟩ c ⟨hi0, hei, hdi, halli⟩ hc
    simp only at hi0 hei hdi halli hc
    unfold check_tgt_defs_loop1.body at hc
    split at hc
    · rename_i hilt
      have hilt' : iI.val < B.insts.val.length := by simpa [i32_lt_iff, hni1] using hilt
      have his := i32_succ_val' hilt' hni2
      obtain ⟨B2, hB2, hc⟩ := bind_eq_ok hc
      rw [hB] at hB2; cases ok_inj' hB2
      obtain ⟨inst, hinst, hc⟩ := bind_eq_ok hc
      obtain ⟨_, hil, hiv⟩ := arr_get_ok hinst
      simp only [inst_dst_spec, bind_ok] at hc
      obtain ⟨t6, ht6, hc⟩ := bind_eq_ok hc
      obtain ⟨q11, hq11, hc⟩ := bind_eq_ok hc
      obtain ⟨t11, vg1⟩ := q11
      try simp only [uncurry_apply_pair] at hc
      obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
      -- the graph grows only through `tgt_effect_c` / `eval_inst`
      have hstep : ∀ vg3, sres = .inr vg3 → vg_extends vgi vg3 ∧ ValGraphDAG vg3 ∧
          ∀ v, 0 ≤ (instDst inst).val → tvid.val[(instDst inst).val.toNat]? = some v → 0 ≤ v.val →
            TgtChecked inst → Valid vg3 v ∧ PureDef vg3 tvid.val inst v := by
        intro vg3 hs3
        subst hs3
        split at hq11
        · rename_i h6
          obtain ⟨B3, hB3, hq11⟩ := bind_eq_ok hq11
          rw [hB] at hB3; cases ok_inj' hB3
          obtain ⟨inst3, hinst3, hq11⟩ := bind_eq_ok hq11
          rw [hinst] at hinst3; cases ok_inj' hinst3
          obtain ⟨q10, hq10, hq11⟩ := bind_eq_ok hq11
          obtain ⟨t10, vg2⟩ := q10
          have e11 := ok_inj' hq11
          simp only [Prod.mk.injEq] at e11
          obtain ⟨ht11, hvg1⟩ := e11
          subst hvg1
          -- `tgt_effect_c` only grows the graph
          have hext2 : vg_extends vgi vg2 ∧ ValGraphDAG vg2 := by
            unfold tgt_effect_c at hq10
            cases inst with
            | Bin d c op a b =>
              simp only [is_trapping_binop_spec, bind_ok] at hq10
              split at hq10
              · cases ok_inj' hq10; exact ⟨vg_extends_refl _, hdi⟩
              · simp only [binop_arg_cls_spec0, binop_arg_cls_spec1, bind_ok] at hq10
                obtain ⟨q1, hq1, hq10⟩ := bind_eq_ok hq10
                obtain ⟨av, vga⟩ := q1
                try simp only [uncurry_apply_pair] at hq10
                obtain ⟨q2, hq2, hq10⟩ := bind_eq_ok hq10
                obtain ⟨bv, vgbb⟩ := q2
                try simp only [uncurry_apply_pair] at hq10
                obtain ⟨t8, -, hq10⟩ := bind_eq_ok hq10
                cases ok_inj' hq10
                have hvi : VidsOK vgi tvid.val := vidsOK_extends (vg_extends_trans heb hei) hv
                obtain ⟨ea, da, -⟩ := atom_use_sound hq1 hdi hvi
                obtain ⟨eb, db, -⟩ := atom_use_sound hq2 da (vidsOK_extends ea hvi)
                exact ⟨vg_extends_trans ea eb, db⟩
            | _ => cases ok_inj' hq10; exact ⟨vg_extends_refl _, hdi⟩
          split at hsres
          · rename_i h11
            obtain ⟨tv, htv, hsres⟩ := bind_eq_ok hsres
            obtain ⟨B4, hB4, hsres⟩ := bind_eq_ok hsres
            rw [hB] at hB4; cases ok_inj' hB4
            obtain ⟨inst4, hinst4, hsres⟩ := bind_eq_ok hsres
            rw [hinst] at hinst4; cases ok_inj' hinst4
            obtain ⟨q17, hq17, hsres⟩ := bind_eq_ok hsres
            obtain ⟨r17, vg7⟩ := q17
            try simp only [uncurry_apply_pair] at hsres
            split at hsres
            · cases ok_inj' hsres
            rename_i heq
            cases ok_inj' hsres
            obtain ⟨e7, d7, h7⟩ := eval_inst_sound hq17 hext2.2
              (vidsOK_extends (vg_extends_trans heb (vg_extends_trans hei hext2.1)) hv)
            dsimp only at e7 d7 h7
            refine ⟨vg_extends_trans hext2.1 e7, d7, fun v hd0 hvv hv0 hck => ?_⟩
            obtain ⟨_, htvl, htvv⟩ := arr_get_ok htv
            have hvt : tv = v := by rw [List.getElem?_eq_getElem htvl, htvv] at hvv; exact Option.some.inj hvv
            subst hvt
            have hr : tv = r17 := i32_ext (by simpa using heq)
            subst hr
            obtain ⟨hvalid, hcase⟩ := h7 hv0
            rcases hcase with hp | ⟨hl, -⟩
            · exact ⟨hvalid, hp⟩
            · cases hl
          · rename_i h11
            cases ok_inj' hsres
            refine ⟨hext2.1, hext2.2, fun v hd0 hvv hv0 hck => ?_⟩
            exfalso
            apply h11
            rw [tgt_effect_c_false hck] at hq10
            cases ok_inj' hq10
            rw [← ht11]; rfl
        · rename_i h6
          cases ok_inj' hq11
          split at hsres
          · rename_i h11; cases h11
          · cases ok_inj' hsres
            refine ⟨vg_extends_refl _, hdi, fun v hd0 hvv hv0 hck => ?_⟩
            exfalso
            apply h6
            split at ht6
            · obtain ⟨tv, htv, ht6⟩ := bind_eq_ok ht6
              cases ok_inj' ht6
              obtain ⟨_, htvl, htvv⟩ := arr_get_ok htv
              have : tv = v := by rw [List.getElem?_eq_getElem htvl, htvv] at hvv; exact Option.some.inj hvv
              subst this
              simpa [i32_le_iff] using hv0
            · rename_i hneg; exact absurd (by simpa [i32_le_iff] using hd0) hneg
      cases sres with
      | inl e =>
        simp only at hc
        rw [← ok_inj' hc]
        show e.1 = false
        split at hsres
        · obtain ⟨tv, -, hsres⟩ := bind_eq_ok hsres
          obtain ⟨B4, -, hsres⟩ := bind_eq_ok hsres
          obtain ⟨inst4, -, hsres⟩ := bind_eq_ok hsres
          obtain ⟨q17, -, hsres⟩ := bind_eq_ok hsres
          obtain ⟨r17, vg7⟩ := q17
          try simp only [uncurry_apply_pair] at hsres
          split at hsres
          · cases ok_inj' hsres; rfl
          · cases ok_inj' hsres
        · cases ok_inj' hsres
      | inr vg3 =>
        simp only at hc
        rw [← ok_inj' hc]
        dsimp only
        obtain ⟨e3, d3, h3⟩ := hstep vg3 rfl
        refine ⟨by omega, vg_extends_trans hei e3, d3, fun i hi hi' v h1 h2 h3' h4 => ?_⟩
        by_cases hii : i = iI.val.toNat
        · subst hii
          rw [hiv]
          exact h3 v (by rw [← hiv]; exact h1) (by rw [← hiv]; exact h2) h3' (by rw [← hiv]; exact h4)
        · obtain ⟨hv1, hp1⟩ := halli i hi (by omega) v h1 h2 h3' h4
          exact ⟨extends_valid e3 hv1, pureDef_extends e3 hv1 hp1⟩
    · rename_i hige
      have hige' : B.insts.val.length ≤ iI.val := by simpa [i32_lt_iff, hni1] using hige
      rw [← ok_inj' hc]
      exact ⟨hei, hdi, fun i hi v h1 h2 h3 h4 => halli i hi (by omega) v h1 h2 h3 h4⟩
  · rename_i hge
    have hge' : f.blocks.val.length ≤ bI.val := by simpa [i32_lt_iff, hnb] using hge
    rw [← ok_inj' hc]
    exact ⟨heb, hdb, fun b hb => hallb b (by omega)⟩

/-! ## Dead edges and folded phis -/

/-- A run leaves the reachable block `p`, whose facts hold, towards `b`. -/
def RunsEdge {W : Type} (G : ValGraph) (f : Func) (info : FnInfo) (vids : List Std.I32)
    (facts : List Fact) (p b : Std.I32) (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv) :
    Prop :=
  0 ≤ p.val ∧ p.val < info.nb.val ∧ info.reach.val[p.val.toNat]? = some true ∧
    (∀ fb ∈ facts, fb.blk = p → FactOK G env fb) ∧
    ∃ P, f.blocks.val[p.val.toNat]? = some P ∧ CondAgree G env vids o regs P.term ∧
      EdgeTaken o regs P.term b

theorem is_self_arm_spec {a : Atom} {d : Std.I32} {r : Bool} (h : is_self_arm a d = ok r) :
    r = true ↔ a = .Temp d := by
  cases a with
  | Temp t => simp only [is_self_arm] at h; cases ok_inj' h; simp [beq_iff_eq]
  | Const _ => simp only [is_self_arm] at h; cases ok_inj' h; simp
  | Sym _ _ => simp only [is_self_arm] at h; cases ok_inj' h; simp

theorem atom_known_true {vids : Pion.Array Std.I32} {a : Atom} (h : atom_known vids a = ok true) :
    ∀ t, a = .Temp t → 0 ≤ t.val ∧ ∃ w, vids.val[t.val.toNat]? = some w ∧ 0 ≤ w.val := by
  intro t ht
  subst ht
  unfold atom_known at h
  simp only at h
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  split at h
  · rename_i htt
    obtain ⟨w, hw, h⟩ := bind_eq_ok h
    obtain ⟨h0, hwl, hwv⟩ := arr_get_ok hw
    have hdec := ok_inj' h
    exact ⟨h0, w, by rw [List.getElem?_eq_getElem hwl, hwv], by simpa [i32_le_iff] using hdec⟩
  · cases ok_inj' h

theorem facts_contradict_true {fs : Pion.Array Fact} (h : facts_contradict fs = ok true) :
    ∃ fa ∈ fs.val, fa.zero = true ∧ ∃ fb ∈ fs.val, fb.vid = fa.vid ∧ fb.zero = false := by
  unfold facts_contradict at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, ht2⟩ := arr_length_ok ht
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun i => facts_contradict_loop0.body t fs i) fs.val.length
    (fun _ => True)
    (fun _ b => b = true → ∃ fa ∈ fs.val, fa.zero = true ∧ ∃ fb ∈ fs.val, fb.vid = fa.vid ∧ fb.zero = false)
    (fun _ => True)
    (by
      intro i c hi hc
      unfold facts_contradict_loop0.body at hc
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, ht1] at hlt
        obtain ⟨fa, hfa, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hfl, hfv⟩ := arr_get_ok hfa
        obtain ⟨t2, ht2', hc⟩ := bind_eq_ok hc
        left
        refine ⟨hlt, ht2, ?_⟩
        split at hc
        · rename_i h2
          left
          refine ⟨true, (ok_inj' hc).symm, fun _ => ?_⟩
          split at ht2'
          · rename_i hz
            obtain ⟨t1, ht1', ht2''⟩ := bind_eq_ok ht2'
            have ht1t : t1 = true := by rw [ok_inj' ht2'']; exact h2
            obtain ⟨fb, hfb, hfbv, hfbz⟩ := (fact_in_spec ht1').1 ht1t
            exact ⟨fa, by rw [← hfv]; exact List.getElem_mem _, hz, fb, hfb, hfbv, hfbz⟩
          · cases ok_inj' ht2'; cases h2
        · right; exact ⟨trivial, (ok_inj' hc).symm⟩
      · rename_i hge
        right; exact ⟨by simpa [i32_lt_iff, ht1] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b =>
    obtain ⟨_, _, _, hb, _⟩ := hk
    simp only at h
    exact hb (ok_inj' h)
  | inr g => simp only at h; cases ok_inj' h

theorem atomAgree_down {W : Type} {vg G : ValGraph} (hp : vg_extends vg G) {env : SymEnv}
    {vids : List Std.I32} {o : WorldOracle W} {regs : Nat → BitVec 64} {a : Atom}
    (h : AtomAgree G env vids o regs a) : AtomAgree vg env vids o regs a :=
  ⟨h.1, fun t ht v hv hvv => by rw [h.2 t ht v hv (extends_valid hp hvv), extends_evI hp env hvv]⟩

/-- A known atom has a value. -/
theorem atom_use_valid {vg : ValGraph} {vids : Pion.Array Std.I32} {cls : Cls} {a : Atom}
    {p : Std.I32 × ValGraph} (h : atom_use vg vids cls a = ok p) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val)
    (hk : ∀ t, a = .Temp t → 0 ≤ t.val ∧ ∃ w, vids.val[t.val.toNat]? = some w ∧ 0 ≤ w.val) :
    0 ≤ p.1.val := by
  unfold atom_use at h
  cases a with
  | Temp t =>
    obtain ⟨ht0, w, hw, hw0⟩ := hk t rfl
    have hwv : Valid vg w := by
      rcases hv _ w hw with rfl | hvw
      · simp at hw0
      · exact hvw
    have htl : t.val.toNat < vids.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hw; cases hw
    simp only at h
    obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
    split at h
    · obtain ⟨v, hgv, h⟩ := bind_eq_ok h
      obtain ⟨_, hvl, hvv⟩ := arr_get_ok hgv
      have : v = w := by rw [List.getElem?_eq_getElem hvl, hvv] at hw; exact Option.some.inj hw
      subst this
      exact (vg_use_sound (pair_ok h) hd hwv).2.2.1.1
    · rename_i h2
      exfalso; apply h2
      split at ht2
      · obtain ⟨n, hn, ht2⟩ := bind_eq_ok ht2
        obtain ⟨hn1, -⟩ := arr_length_ok hn
        cases ok_inj' ht2
        simp only [decide_eq_true_eq, i32_lt_iff]; omega
      · rename_i hneg; exact absurd (by simpa [i32_le_iff] using ht0) hneg
  | Const x =>
    simp only at h
    exact (konst_facts hd (pair_ok h)).2.2.1.1
  | Sym id off =>
    simp only at h
    obtain ⟨q, hq, h⟩ := bind_eq_ok h
    obtain ⟨sv, vg3⟩ := q
    obtain ⟨e3, d3, n3, -, -⟩ := vg_intern_spec hq hd trivial
    have hsv : Valid vg3 sv := nodeAt_valid n3
    have hsc : clsOf vg3 sv = .L := by rw [clsOf_node n3]; rfl
    try simp only [uncurry_apply_pair] at h
    obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
    obtain ⟨r, vg4⟩ := q2
    have hr : vg_extends vg3 vg4 ∧ ValGraphDAG vg4 ∧ Valid vg4 r := by
      split at hq2
      · cases ok_inj' hq2; exact ⟨vg_extends_refl _, d3, hsv⟩
      · obtain ⟨q5, hq5, hq2⟩ := bind_eq_ok hq2
        obtain ⟨o, vg5⟩ := q5
        obtain ⟨e5, d5, vo, co, -, -⟩ := konst_facts d3 hq5
        try simp only [uncurry_apply_pair] at hq2
        obtain ⟨e6, d6, v6, -, -⟩ := vg_canon_bin_sound (pair_ok hq2) d5 (extends_valid e5 hsv) vo
          (by unfold BinArgOK; simp only [isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
              exact ⟨by rw [extends_clsOf e5 hsv, hsc], co⟩)
        exact ⟨vg_extends_trans e5 e6, d6, v6⟩
    try simp only [uncurry_apply_pair] at h
    exact (vg_use_sound (pair_ok h) hr.2.1 hr.2.2).2.2.1.1

/-- `edge_dead`: no run takes an edge the checker declares dead. -/
theorem edge_dead_sound {vg : ValGraph} {f : Func} {info : FnInfo} {vids : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {p b : Std.I32} {q : Bool × ValGraph}
    (h : edge_dead vg f info vids facts p b = ok q) (hd : ValGraphDAG vg) (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (q.1 = true → ∀ G, vg_extends q.2 G →
      ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
        ¬ RunsEdge G f info vids.val facts.val p b o regs env) := by
  unfold edge_dead at h
  obtain ⟨t1, ht1, h⟩ := bind_eq_ok h
  split at h
  · rename_i h1
    cases ok_inj' h
    refine ⟨vg_extends_refl _, hd, fun _ G _ W o regs env hrun => ?_⟩
    obtain ⟨hp0, hpn, hreach, -⟩ := hrun
    split at ht1
    · rename_i hrange
      simp only [Bool.or_eq_true, decide_eq_true_eq, i32_lt_iff, i32_le_iff, i32_zero_val] at hrange
      omega
    · obtain ⟨r, hr, ht1⟩ := bind_eq_ok ht1
      obtain ⟨_, hrl, hrv⟩ := arr_get_ok hr
      cases ok_inj' ht1
      rw [List.getElem?_eq_getElem hrl, hrv] at hreach
      cases hreach
      exact absurd h1 (by decide)
  rename_i h1
  obtain ⟨fs, hfs, h⟩ := bind_eq_ok h
  have hfs' : ∀ fa, fa ∈ fs.val → fa ∈ facts.val ∧ fa.blk = p := fun fa hfa => mem_facts_of hfs hfa
  obtain ⟨t3, ht3, h⟩ := bind_eq_ok h
  split at h
  · rename_i h3
    cases ok_inj' h
    refine ⟨vg_extends_refl _, hd, fun _ G _ W o regs env hrun => ?_⟩
    obtain ⟨-, -, -, hfacts, -⟩ := hrun
    obtain ⟨fa, hfa, hz, fb, hfb, hfbv, hfbz⟩ := facts_contradict_true (h3 ▸ ht3)
    have ha := hfacts fa (hfs' fa hfa).1 (hfs' fa hfa).2
    have hb := hfacts fb (hfs' fb hfb).1 (hfs' fb hfb).2
    obtain ⟨-, -, hbn⟩ := hb
    obtain ⟨-, haz, -⟩ := ha
    rw [hfbv] at hbn
    exact hbn hfbz (haz hz)
  rename_i h3
  obtain ⟨P, hP, h⟩ := bind_eq_ok h
  obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
  try simp only at h
  generalize hT : P.term = T at h
  cases T with
  | Jnz c s1 s2 =>
    try simp only at h
    obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
    split at h
    · rename_i h7
      have hne : s1 ≠ s2 ∧ atom_known vids c = ok true := by
        split at ht7
        · rename_i hne
          obtain ⟨t6, ht6, ht7'⟩ := bind_eq_ok ht7
          have e67 : t6 = t7 := ok_inj' ht7'
          exact ⟨hne, by rw [ht6, e67, h7]⟩
        · cases ok_inj' ht7; cases h7
      obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
      obtain ⟨cv0, vg1⟩ := q1
      try simp only [uncurry_apply_pair] at h
      obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
      obtain ⟨cv, vg2⟩ := q2
      try simp only [uncurry_apply_pair] at h
      obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hd hv
      dsimp only at e1 d1 h1u
      obtain ⟨e2, d2, h2v, -⟩ := apply_facts_sound hq2 d1
      dsimp only at e2 d2 h2v
      obtain ⟨t14, ht14, h⟩ := bind_eq_ok h
      cases t14 with
      | none =>
        simp only at h
        cases ok_inj' h
        exact ⟨vg_extends_trans e1 e2, d2, fun hc => by cases hc⟩
      | some x =>
        simp only at h
        cases ok_inj' h
        refine ⟨vg_extends_trans e1 e2, d2, fun hdead G hG W o regs env hrun => ?_⟩
        obtain ⟨hp0, -, -, hfacts, P', hP', hca, het⟩ := hrun
        rw [List.getElem?_eq_getElem hPl, hPv] at hP'
        cases hP'
        rw [hT] at hca het
        have hx := vg_const_some ht14
        have hcv0 : 0 ≤ cv0.val := atom_use_valid hq1 hd hv (atom_known_true hne.2)
        obtain ⟨vcv0, -, -, -⟩ := h1u hcv0
        obtain ⟨vcv, valcv⟩ := h2v vcv0
        have hfsh : FactsHold G env fs.val := fun fa hfa =>
          hfacts fa (hfs' fa hfa).1 (hfs' fa hfa).2
        have hcond : atomVal o regs .W c = x.bv := by
          have hag : AtomAgree vg env vids.val o regs c :=
            atomAgree_down (vg_extends_trans e1 (vg_extends_trans e2 hG)) hca
          rw [← atom_use_val hq1 hd hv hcv0 hag]
          dsimp only
          rw [← valcv G env hG hfsh]
          exact constOf_evI d2 env hx.1
        simp only [EdgeTaken] at het
        rw [hcond] at het
        simp only [bne_iff_ne, ne_eq] at hdead
        have hxb : x ≠ 0#u64 ↔ x.bv ≠ 0 := by rw [u64_ne]; exact Iff.rfl
        rw [het] at hdead
        revert hdead
        simp [hxb]
    · cases ok_inj' h
      exact ⟨vg_extends_refl _, hd, fun hc => by cases hc⟩
  | _ =>
    try simp only at h
    cases ok_inj' h
    exact ⟨vg_extends_refl _, hd, fun hc => by cases hc⟩

/-- One arm of a folded phi: the phi's own temp, a dead edge, or the folded value `cand`. -/
def FoldArm (G : ValGraph) (f : Func) (info : FnInfo) (vids : List Std.I32) (facts : List Fact)
    (b : Std.I32) (P : Phi) (cand : Std.I32) (a : PhiArm) : Prop :=
  a.value = .Temp P.dst ∨
  (∀ G', vg_extends G G' → ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
      ¬ RunsEdge G' f info vids facts a.pred b o regs env) ∨
  (0 ≤ cand.val ∧ Valid G cand ∧ AtomKnown G vids a.value ∧
    ∀ env, evI G env cand = maskC P.cls (atomSem G env vids a.value))

theorem foldArm_extends {G G' : ValGraph} (hp : vg_extends G G') {f : Func} {info : FnInfo}
    {vids : List Std.I32} {facts : List Fact} {b : Std.I32} {P : Phi} {cand : Std.I32} {a : PhiArm}
    (h : FoldArm G f info vids facts b P cand a) : FoldArm G' f info vids facts b P cand a := by
  rcases h with h | h | ⟨h0, hv, hk, he⟩
  · exact Or.inl h
  · exact Or.inr (Or.inl fun G'' e => h G'' (vg_extends_trans hp e))
  · refine Or.inr (Or.inr ⟨h0, extends_valid hp hv, atomKnown_extends hp hk, fun env => ?_⟩)
    rw [extends_evI hp env hv, atomSem_extends hp hk, he env]

theorem foldArm_cand {G : ValGraph} {f : Func} {info : FnInfo}
    {vids : List Std.I32} {facts : List Fact} {b : Std.I32} {P : Phi} {cand cand' : Std.I32} {a : PhiArm}
    (h : FoldArm G f info vids facts b P cand a) (hc : ¬ 0 ≤ cand.val) :
    FoldArm G f info vids facts b P cand' a := by
  rcases h with h | h | ⟨h0, -⟩
  · exact Or.inl h
  · exact Or.inr (Or.inl h)
  · exact absurd h0 hc

theorem mask_ext {g g' : ValGraph} (hp : vg_extends g g') {c : Cls} {x : Std.I32}
    (h : Valid g x ∧ ∀ env, maskC c (evI g env x) = evI g env x) :
    Valid g' x ∧ ∀ env, maskC c (evI g' env x) = evI g' env x :=
  ⟨extends_valid hp h.1, fun env => by rw [extends_evI hp env h.1]; exact h.2 env⟩

/-- `phi_fold`: a non-negative result is a value not depending on `b` that every arm of the
phi on a live edge, other than the phi itself, has. -/
theorem phi_fold_sound {vg : ValGraph} {f : Func} {info : FnInfo} {vids : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {b k : Std.I32} {q : Std.I32 × ValGraph}
    (h : phi_fold vg f info vids facts b k = ok q) (hd : ValGraphDAG vg) (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (0 ≤ q.1.val → ∃ B P, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k.val.toNat]? = some P ∧
        Valid q.2 q.1 ∧ (∀ env, maskC P.cls (evI q.2 env q.1) = evI q.2 env q.1) ∧
        vid_mentions_blk q.2 q.1 b = ok false ∧
        ∀ a ∈ P.arms.val, FoldArm q.2 f info vids.val facts.val b P q.1 a) := by
  unfold phi_fold at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨P, hP, h⟩ := bind_eq_ok h
  obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
  obtain ⟨B2, hB2, h⟩ := bind_eq_ok h
  rw [hB] at hB2; cases ok_inj' hB2
  obtain ⟨P2, hP2, h⟩ := bind_eq_ok h
  rw [hP] at hP2; cases ok_inj' hP2
  obtain ⟨B3, hB3, h⟩ := bind_eq_ok h
  rw [hB] at hB3; cases ok_inj' hB3
  obtain ⟨P3, hP3, h⟩ := bind_eq_ok h
  rw [hP] at hP3; cases ok_inj' hP3
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  have hPk : B.phis.val[k.val.toNat]? = some P := by rw [List.getElem?_eq_getElem hPl, hPv]
  unfold phi_fold_loop0 at hs
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph × Std.I32 × Bool) =>
      match x with
      | (j, vg, cand, same) => phi_fold_loop0.body n f b k P.dst info vids facts P.cls j vg cand same)
    (fun x => 0 ≤ x.1.val ∧ vg_extends vg x.2.1 ∧ ValGraphDAG x.2.1 ∧
      (0 ≤ x.2.2.1.val → Valid x.2.1 x.2.2.1 ∧
        ∀ env, maskC P.cls (evI x.2.1 env x.2.2.1) = evI x.2.1 env x.2.2.1) ∧
      (x.2.2.2 = true → ∀ j (hj : j < P.arms.val.length), j < x.1.val.toNat →
        FoldArm x.2.1 f info vids.val facts.val b P x.2.2.1 P.arms.val[j]))
    (fun r => match r with
      | .inl e => vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ e.1 = (-2)#i32
      | .inr y => vg_extends vg y.2.1 ∧ ValGraphDAG y.2.1 ∧ (0 ≤ y.2.2.1.val → Valid y.2.1 y.2.2.1 ∧
            ∀ env, maskC P.cls (evI y.2.1 env y.2.2.1) = evI y.2.1 env y.2.2.1) ∧
          (y.2.2.2 = true → ∀ a ∈ P.arms.val, FoldArm y.2.1 f info vids.val facts.val b P y.2.2.1 a))
    ?_ _ _ hs ⟨by simp, vg_extends_refl _, hd, fun h => by simp at h, fun _ j _ hj => by simp at hj⟩
  · cases s with
    | inl e =>
      simp only at h
      rw [← ok_inj' h]
      obtain ⟨e1, d1, he⟩ := key
      refine ⟨e1, d1, fun hq => ?_⟩
      rw [he] at hq; simp at hq
    | inr y =>
      obtain ⟨j1, vg1, cand1, same1⟩ := y
      simp only at h
      obtain ⟨e1, d1, hc1, hall⟩ := key
      split at h
      · rename_i hsc
        obtain ⟨t19, ht19, h⟩ := bind_eq_ok h
        rw [← ok_inj' h]
        refine ⟨e1, d1, fun hq => ?_⟩
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hsc
        have hc0 : 0 ≤ cand1.val := by have := hsc.2; simpa [i32_le_iff, ge_iff_le] using this
        cases t19 with
        | true => simp at hq
        | false =>
          simp only [Bool.not_false, ↓reduceIte] at hq ⊢
          exact ⟨B, P, hBb, hPk, (hc1 hc0).1, (hc1 hc0).2, ht19, hall hsc.1⟩
      · rw [← ok_inj' h]
        refine ⟨e1, d1, fun hq => ?_⟩
        simp at hq
  rintro ⟨jI, vgj, cand, same⟩ c ⟨hj0, hej, hdj, hcv, hall⟩ hc
  simp only at hj0 hej hdj hcv hall hc
  unfold phi_fold_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : jI.val < P.arms.val.length := by simpa [i32_lt_iff, hn1] using hlt
    have hjs := i32_succ_val' hlt' hn2
    obtain ⟨B4, hB4, hc⟩ := bind_eq_ok hc
    rw [hB] at hB4; cases ok_inj' hB4
    obtain ⟨P4, hP4, hc⟩ := bind_eq_ok hc
    rw [hP] at hP4; cases ok_inj' hP4
    obtain ⟨A, hA, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hAl, hAv⟩ := arr_get_ok hA
    obtain ⟨B5, hB5, hc⟩ := bind_eq_ok hc
    rw [hB] at hB5; cases ok_inj' hB5
    obtain ⟨P5, hP5, hc⟩ := bind_eq_ok hc
    rw [hP] at hP5; cases ok_inj' hP5
    obtain ⟨A2, hA2, hc⟩ := bind_eq_ok hc
    rw [hA] at hA2; cases ok_inj' hA2
    obtain ⟨t13, ht13, hc⟩ := bind_eq_ok hc
    have hself := is_self_arm_spec ht13
    obtain ⟨q16, hq16, hc⟩ := bind_eq_ok hc
    obtain ⟨t16, vg1⟩ := q16
    try simp only [uncurry_apply_pair] at hc
    have hvj : VidsOK vgj vids.val := vidsOK_extends hej hv
    have h16 : vg_extends vgj vg1 ∧ ValGraphDAG vg1 ∧ (t16 = false → A.value = .Temp P.dst ∨
        ∀ G', vg_extends vg1 G' → ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
          ¬ RunsEdge G' f info vids.val facts.val A.pred b o regs env) := by
      split at hq16
      · obtain ⟨q15, hq15, hq16⟩ := bind_eq_ok hq16
        obtain ⟨t15, vg2⟩ := q15
        try simp only [uncurry_apply_pair] at hq16
        cases ok_inj' hq16
        obtain ⟨e2, d2, hdead⟩ := edge_dead_sound hq15 hdj hvj
        refine ⟨e2, d2, fun ht => Or.inr (hdead ?_)⟩
        simpa using ht
      · rename_i hs13
        cases ok_inj' hq16
        exact ⟨vg_extends_refl _, hdj, fun _ => Or.inl (hself.1 (by simpa using hs13))⟩
    obtain ⟨e1, d1, h1⟩ := h16
    have hAj : P.arms.val[jI.val.toNat] = A := hAv
    -- the old arms survive any growth of the graph
    have old : ∀ g cand', vg_extends vg1 g → (¬ 0 ≤ cand.val ∨ cand' = cand) → same = true →
        ∀ j (hj : j < P.arms.val.length), j < jI.val.toNat →
          FoldArm g f info vids.val facts.val b P cand' P.arms.val[j] := by
      intro g cand' eg hcc hsame j hj hjl
      have := foldArm_extends (vg_extends_trans e1 eg) (hall hsame j hj hjl)
      rcases hcc with hcc | rfl
      · exact foldArm_cand this hcc
      · exact this
    obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
    have hst : (∃ e, sres = .inl e ∧ vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ e.1 = (-2)#i32) ∨
        (∃ vg4 cand2 same2, sres = .inr (vg4, cand2, same2) ∧ vg_extends vgj vg4 ∧ ValGraphDAG vg4 ∧
          (0 ≤ cand2.val → Valid vg4 cand2 ∧ ∀ env, maskC P.cls (evI vg4 env cand2) = evI vg4 env cand2) ∧
          (same2 = true → ∀ j (hj : j < P.arms.val.length), j < jI.val.toNat + 1 →
            FoldArm vg4 f info vids.val facts.val b P cand2 P.arms.val[j])) := by
      split at hsres
      · rename_i ht16
        obtain ⟨q3, hq3, hsres⟩ := bind_eq_ok hsres
        obtain ⟨v, vg3⟩ := q3
        try simp only [uncurry_apply_pair] at hsres
        obtain ⟨e3, d3, h3⟩ := atom_use_sound hq3 d1 (vidsOK_extends e1 hvj)
        dsimp only at e3 d3 h3
        split at hsres
        · cases ok_inj' hsres
          exact Or.inl ⟨_, rfl, vg_extends_trans hej (vg_extends_trans e1 e3), d3, rfl⟩
        rename_i hv0
        have hv0' : 0 ≤ v.val := by simpa [i32_lt_iff] using hv0
        obtain ⟨vv, -, vk, vs⟩ := h3 hv0'
        have hknown : AtomKnown vg3 vids.val A.value := atomKnown_extends e3 vk
        have hsem : ∀ env, evI vg3 env v = maskC P.cls (atomSem vg3 env vids.val A.value) := fun env => by
          rw [vs env, atomSem_extends e3 vk]
        have hnew : ∀ cand', cand' = v →
            FoldArm vg3 f info vids.val facts.val b P cand' P.arms.val[jI.val.toNat] := by
          rintro _ rfl
          rw [hAj]
          exact Or.inr (Or.inr ⟨hv0', vv, hknown, hsem⟩)
        split at hsres
        · rename_i hcneg
          cases ok_inj' hsres
          refine Or.inr ⟨_, _, _, rfl, vg_extends_trans e1 e3, d3,
            fun _ => ⟨vv, fun env => by rw [hsem env, maskC_idem]⟩, fun hsame j hj hjl => ?_⟩
          by_cases hjj : j = jI.val.toNat
          · subst hjj; exact hnew _ rfl
          · exact old vg3 v e3 (Or.inl (by simpa [i32_lt_iff] using hcneg)) hsame j hj (by omega)
        · rename_i hcpos
          split at hsres
          · cases ok_inj' hsres
            refine Or.inr ⟨_, _, _, rfl, vg_extends_trans e1 e3, d3,
              fun h0 => mask_ext (vg_extends_trans e1 e3) (hcv h0), fun hf => by cases hf⟩
          · rename_i hne
            cases ok_inj' hsres
            have hvc : v = cand := i32_ext (by simpa using hne)
            refine Or.inr ⟨_, _, _, rfl, vg_extends_trans e1 e3, d3,
              fun h0 => mask_ext (vg_extends_trans e1 e3) (hcv h0), fun hsame j hj hjl => ?_⟩
            by_cases hjj : j = jI.val.toNat
            · subst hjj; exact hnew _ hvc.symm
            · exact old vg3 cand e3 (Or.inr rfl) hsame j hj (by omega)
      · rename_i ht16
        cases ok_inj' hsres
        have ht16' : t16 = false := by simpa using ht16
        refine Or.inr ⟨_, _, _, rfl, e1, d1, fun h0 => mask_ext e1 (hcv h0), fun hsame j hj hjl => ?_⟩
        by_cases hjj : j = jI.val.toNat
        · subst hjj
          rw [hAj]
          rcases h1 ht16' with hs | hdead
          · exact Or.inl hs
          · exact Or.inr (Or.inl hdead)
        · exact old vg1 cand (vg_extends_refl _) (Or.inr rfl) hsame j hj (by omega)
    rcases hst with ⟨e, rfl, he1, he2, he3⟩ | ⟨vg4, cand2, same2, rfl, h4e, h4d, h4c, h4a⟩
    · simp only at hc
      rw [← ok_inj' hc]
      exact ⟨he1, he2, he3⟩
    · simp only at hc
      rw [← ok_inj' hc]
      dsimp only
      refine ⟨by omega, vg_extends_trans hej h4e, h4d, h4c, fun hs j hj hjl => h4a hs j hj (by omega)⟩
  · rename_i hge
    have hge' : P.arms.val.length ≤ jI.val := by simpa [i32_lt_iff, hn1] using hge
    rw [← ok_inj' hc]
    refine ⟨hej, hdj, hcv, fun hs a ha => ?_⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem ha
    exact hall hs j hj (by omega)

/-! ## Sole predecessors -/

/-- How many times block `y` names `p` as a successor. -/
def succCnt (f : Func) (p : Std.I32) (y : Nat) : Nat :=
  match f.blocks.val[y]? with
  | some B => (termSuccs B.term).count p
  | none => 0

/-- How many times blocks `< x` name `p` as a successor. -/
def succOcc (f : Func) (p : Std.I32) : Nat → Nat
  | 0 => 0
  | x + 1 => succOcc f p x + succCnt f p x

theorem succCnt_le (f : Func) (p : Std.I32) (y : Nat) : succCnt f p y ≤ 2 := by
  unfold succCnt
  split
  · rename_i B _
    have h1 := List.count_le_length (a := p) (l := termSuccs B.term)
    have h2 : (termSuccs B.term).length ≤ 2 := by cases B.term <;> simp [termSuccs]
    omega
  · omega

theorem succOcc_le (f : Func) (p : Std.I32) : ∀ x, succOcc f p x ≤ 2 * x
  | 0 => by simp [succOcc]
  | x + 1 => by have := succOcc_le f p x; have := succCnt_le f p x; simp only [succOcc]; omega

theorem succOcc_ge (f : Func) (p : Std.I32) : ∀ x y, y < x → succCnt f p y ≤ succOcc f p x
  | 0, y, h => absurd h (by omega)
  | x + 1, y, h => by
    simp only [succOcc]
    by_cases hy : y = x
    · subst hy; omega
    · have := succOcc_ge f p x y (by omega); omega

theorem succOcc_two (f : Func) (p : Std.I32) : ∀ x y z, y < z → z < x →
    succCnt f p y + succCnt f p z ≤ succOcc f p x
  | 0, y, z, _, h => absurd h (by omega)
  | x + 1, y, z, hyz, hzx => by
    simp only [succOcc]
    by_cases hz : z = x
    · subst hz; have := succOcc_ge f p z y hyz; omega
    · have := succOcc_two f p x y z hyz (by omega); omega

theorem succCnt_pos {f : Func} {p : Std.I32} {y : Nat} {B : Block} (hB : f.blocks.val[y]? = some B) :
    0 < succCnt f p y ↔ p ∈ termSuccs B.term := by
  unfold succCnt; rw [hB]; exact List.count_pos_iff

theorem i32_bv_add (a b : Std.I32) : (Pion.I32.add a b).bv.toNat = (a.bv.toNat + b.bv.toNat) % 2 ^ 32 := by
  have e : (Pion.I32.add a b).bv = a.bv + b.bv := by simp
  rw [e, BitVec.toNat_add]

theorem i32_bv_add_one (a : Std.I32) : (Pion.I32.add a 1#i32).bv.toNat = (a.bv.toNat + 1) % 2 ^ 32 := by
  rw [i32_bv_add]
  rfl

/-- `sole_pred f p`: the one block having `p` as a successor (once). -/
theorem sole_pred_sound {f : Func} {p r : Std.I32} (h : sole_pred f p = ok r) (hr : 0 ≤ r.val) :
    r.val < f.blocks.val.length ∧ (∃ B, f.blocks.val[r.val.toNat]? = some B ∧ p ∈ termSuccs B.term) ∧
    ∀ y (B : Block), f.blocks.val[y]? = some B → p ∈ termSuccs B.term → y = r.val.toNat := by
  unfold sole_pred at h
  obtain ⟨nb, hnb, h⟩ := bind_eq_ok h
  obtain ⟨hnb1, hnb2⟩ := arr_length_ok hnb
  obtain ⟨res, hres, h⟩ := bind_eq_ok h
  obtain ⟨x1, found1, count1⟩ := res
  change ok (if count1 = 1#i32 then found1 else (-1)#i32) = ok r at h
  unfold sole_pred_loop0 at hres
  have key := loop_ok_inv (fun (x : Std.I32 × Std.I32 × Std.I32) =>
      match x with | (x, found, count) => sole_pred_loop0.body nb f p x found count)
    (fun x => 0 ≤ x.1.val ∧ x.1.val ≤ nb.val ∧
      x.2.2.bv.toNat = succOcc f p x.1.val.toNat % 2 ^ 32 ∧
      (0 < succOcc f p x.1.val.toNat → 0 ≤ x.2.1.val ∧ x.2.1.val < x.1.val ∧
        0 < succCnt f p x.2.1.val.toNat))
    (fun y => y.2.2.bv.toNat = succOcc f p f.blocks.val.length % 2 ^ 32 ∧
      (0 < succOcc f p f.blocks.val.length → 0 ≤ y.2.1.val ∧ y.2.1.val < f.blocks.val.length ∧
        0 < succCnt f p y.2.1.val.toNat))
    ?_ _ _ hres ⟨by simp, by simp; omega, by simp [succOcc], fun h => by simp [succOcc] at h⟩
  · obtain ⟨hc, hf⟩ := key
    dsimp only at hc hf
    split at h
    · rename_i h1
      have hr' : found1 = r := ok_inj' h
      subst hr' h1
      have hocc : succOcc f p f.blocks.val.length = 1 := by
        have := succOcc_le f p f.blocks.val.length
        have h1 : succOcc f p f.blocks.val.length % 2 ^ 32 = 1 := by rw [← hc]; decide
        omega
      obtain ⟨hf0, hfl, hfc⟩ := hf (by omega)
      obtain ⟨B, hB⟩ : ∃ B, f.blocks.val[found1.val.toNat]? = some B :=
        ⟨_, List.getElem?_eq_getElem (by omega)⟩
      refine ⟨hfl, ⟨B, hB, (succCnt_pos hB).1 hfc⟩, fun y B' hB' hp => ?_⟩
      have hy : y < f.blocks.val.length := by
        by_contra hc; rw [List.getElem?_eq_none (by omega)] at hB'; cases hB'
      have hyc := (succCnt_pos hB').2 hp
      by_contra hne
      rcases Nat.lt_or_gt_of_ne hne with hlt | hlt
      · have := succOcc_two f p _ _ _ hlt (show found1.val.toNat < f.blocks.val.length by omega); omega
      · have := succOcc_two f p _ _ _ hlt hy; omega
    · cases ok_inj' h; simp at hr
  rintro ⟨xI, found, count⟩ c ⟨hx0, hxn, hcnt, hfnd⟩ hc
  replace hfnd : 0 < succOcc f p xI.val.toNat → 0 ≤ found.val ∧ found.val < xI.val ∧
    0 < succCnt f p found.val.toNat := hfnd
  replace hcnt : count.bv.toNat = succOcc f p xI.val.toNat % 2 ^ 32 := hcnt
  replace hxn : xI.val ≤ nb.val := hxn
  replace hx0 : 0 ≤ xI.val := hx0
  try dsimp only at hc
  unfold sole_pred_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : xI.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb1] using hlt
    have hxs := i32_succ_val' hlt' hnb2
    obtain ⟨B, hB, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
    have hBb : f.blocks.val[xI.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
    simp only [term_nsucc_spec, bind_ok] at hc
    obtain ⟨q1, hq1, hc⟩ := bind_eq_ok hc
    obtain ⟨k1, found1, count1⟩ := q1
    rw [← ok_inj' hc]
    dsimp only
    unfold sole_pred_loop1 at hq1
    have hlen : (termSuccs B.term).length ≤ 2 := by cases B.term <;> simp [termSuccs]
    have key1 := loop_ok_inv (fun (x : Std.I32 × Std.I32 × Std.I32) =>
        match x with
        | (k, fd, ct) => sole_pred_loop1.body ⟨BitVec.ofNat 32 (termSuccs B.term).length⟩ B.term p xI k fd ct)
      (fun x => 0 ≤ x.1.val ∧ x.1.val ≤ (termSuccs B.term).length ∧
        x.2.2.bv.toNat = (count.bv.toNat + ((termSuccs B.term).take x.1.val.toNat).count p) % 2 ^ 32 ∧
        (((termSuccs B.term).take x.1.val.toNat).count p = 0 → x.2.1 = found) ∧
        (0 < ((termSuccs B.term).take x.1.val.toNat).count p → x.2.1 = xI))
      (fun y => y.2.2.bv.toNat = (count.bv.toNat + (termSuccs B.term).count p) % 2 ^ 32 ∧
        ((termSuccs B.term).count p = 0 → y.2.1 = found) ∧
        (0 < (termSuccs B.term).count p → y.2.1 = xI))
      ?_ _ _ hq1 ⟨by simp, by simp, by simp; omega, fun _ => rfl, fun h => by simp at h⟩
    · obtain ⟨hc1, hf1, hf2⟩ := key1
      dsimp only at hc1 hf1 hf2
      have hcB : succCnt f p xI.val.toNat = (termSuccs B.term).count p := by unfold succCnt; rw [hBb]
      have hso : succOcc f p (xI.val + 1).toNat = succOcc f p xI.val.toNat + succCnt f p xI.val.toNat := by
        rw [show (xI.val + 1).toNat = xI.val.toNat + 1 by omega]; rfl
      refine ⟨by omega, by omega, ?_, fun hpos => ?_⟩
      · rw [hxs, hso, hc1, hcnt, hcB]; omega
      · rw [hxs, hso] at hpos
        by_cases hz : (termSuccs B.term).count p = 0
        · rw [hf1 hz]
          rw [hcB, hz] at hpos
          obtain ⟨a1, a2, a3⟩ := hfnd (by omega)
          exact ⟨a1, by omega, a3⟩
        · rw [hf2 (by omega)]
          exact ⟨hx0, by omega, by rw [hcB]; omega⟩
    rintro ⟨kI, fd, ct⟩ c ⟨hk0, hkn, hct, hz, hp⟩ hc
    replace hk0 : 0 ≤ kI.val := hk0
    replace hkn : kI.val ≤ (termSuccs B.term).length := hkn
    replace hct : ct.bv.toNat = (count.bv.toNat + ((termSuccs B.term).take kI.val.toNat).count p) % 2 ^ 32 := hct
    replace hz : ((termSuccs B.term).take kI.val.toNat).count p = 0 → fd = found := hz
    replace hp : 0 < ((termSuccs B.term).take kI.val.toNat).count p → fd = xI := hp
    try dsimp only at hc
    unfold sole_pred_loop1.body at hc
    split at hc
    · rename_i hklt
      have hklt' : kI.val < (termSuccs B.term).length := by simpa [i32_lt_iff, nsucc_val] using hklt
      have hks : (Pion.I32.add kI 1#i32).val = kI.val + 1 := i32_succ_val' hklt' (by omega)
      rw [term_succ_spec _ _ hk0 hklt', bind_ok] at hc
      have htake : (termSuccs B.term).take (kI.val + 1).toNat =
          (termSuccs B.term).take kI.val.toNat ++ [(termSuccs B.term)[kI.val.toNat]'(by omega)] := by
        rw [show (kI.val + 1).toNat = kI.val.toNat + 1 by omega, List.take_add_one,
          List.getElem?_eq_getElem (by omega)]
        rfl
      obtain ⟨q2, hq2, hc⟩ := bind_eq_ok hc
      obtain ⟨fd2, ct2⟩ := q2
      simp only at hc
      rw [← ok_inj' hc]
      dsimp only
      rw [hks, htake, List.count_append]
      split at hq2
      · rename_i heq
        cases ok_inj' hq2
        have h1 : [(termSuccs B.term)[kI.val.toNat]'(by omega)].count p = 1 := by
          rw [heq]; simp
        rw [h1]
        refine ⟨by omega, by omega, by rw [i32_bv_add_one, hct]; omega, fun h => by omega, fun _ => rfl⟩
      · rename_i hne
        cases ok_inj' hq2
        have h1 : [(termSuccs B.term)[kI.val.toNat]'(by omega)].count p = 0 := by
          simp only [List.count_singleton]; simp [hne]
        rw [h1]
        exact ⟨by omega, by omega, by rw [hct, Nat.add_zero], fun h => hz (by omega), fun h => hp (by omega)⟩
    · rename_i hkge
      have hkge' : (termSuccs B.term).length ≤ kI.val := by simpa [i32_lt_iff, nsucc_val] using hkge
      rw [← ok_inj' hc]
      have ht : (termSuccs B.term).take kI.val.toNat = termSuccs B.term := List.take_of_length_le (by omega)
      rw [ht] at hct hz hp
      exact ⟨hct, hz, hp⟩
  · rename_i hge
    have hge' : f.blocks.val.length ≤ xI.val := by simpa [i32_lt_iff, hnb1] using hge
    rw [← ok_inj' hc]
    dsimp only
    have hx : xI.val.toNat = f.blocks.val.length := by omega
    rw [hx] at hcnt hfnd
    exact ⟨hcnt, fun h => by obtain ⟨a, b, c⟩ := hfnd h; exact ⟨a, by omega, c⟩⟩

/-! ## Phis selecting 0/1 by a branch -/

/-- `v` is the 0/1 value phi `P` of block `b` takes: its arm from `p1` is `1`, from `p0` is `0`,
and `p1`, `p0` are the two arms of the only `jnz cond` naming them. -/
def SelOK (G : ValGraph) (f : Func) (vids : List Std.I32) (b : Std.I32) (P : Phi) (v : Std.I32) : Prop :=
  ∃ (p1 p0 d : Std.I32) (cond : Atom), p1 ≠ p0 ∧
    (∀ a ∈ P.arms.val,
      (a.pred = p1 ∧ AtomKnown G vids a.value ∧ ∀ env, maskC P.cls (atomSem G env vids a.value) = 1) ∨
      (a.pred = p0 ∧ AtomKnown G vids a.value ∧ ∀ env, maskC P.cls (atomSem G env vids a.value) = 0)) ∧
    0 ≤ d.val ∧
    (∀ y (By : Block), f.blocks.val[y]? = some By → p1 ∈ termSuccs By.term → y = d.val.toNat) ∧
    (∀ y (By : Block), f.blocks.val[y]? = some By → p0 ∈ termSuccs By.term → y = d.val.toNat) ∧
    (∃ Bd, f.blocks.val[d.val.toNat]? = some Bd ∧ Bd.term = .Jnz cond p1 p0) ∧
    AtomKnown G vids cond ∧ Valid G v ∧
    (∀ env, evI G env v = if maskC .W (atomSem G env vids cond) = 0 then 0 else 1) ∧
    (∀ x, (x = b ∨ x = p1 ∨ x = p0) → ∀ env env', AgreeExcept x env env' → evI G env' v = evI G env v)

theorem selOK_extends {G G' : ValGraph} (hp : vg_extends G G') {f : Func} {vids : List Std.I32}
    {b : Std.I32} {P : Phi} {v : Std.I32} (h : SelOK G f vids b P v) : SelOK G' f vids b P v := by
  obtain ⟨p1, p0, d, cond, hne, harms, hd0, hs1, hs0, hBd, hk, hv, hval, hst⟩ := h
  refine ⟨p1, p0, d, cond, hne, fun a ha => ?_, hd0, hs1, hs0, hBd, atomKnown_extends hp hk,
    extends_valid hp hv, fun env => ?_, fun x hx env env' he => ?_⟩
  · rcases harms a ha with ⟨h1, h2, h3⟩ | ⟨h1, h2, h3⟩
    · exact Or.inl ⟨h1, atomKnown_extends hp h2, fun env => by rw [atomSem_extends hp h2]; exact h3 env⟩
    · exact Or.inr ⟨h1, atomKnown_extends hp h2, fun env => by rw [atomSem_extends hp h2]; exact h3 env⟩
  · rw [extends_evI hp env hv, atomSem_extends hp hk]; exact hval env
  · rw [extends_evI hp env hv, extends_evI hp env' hv]; exact hst x hx env env' he

theorem maskC_small (c : Cls) (x : BitVec 64) (h : x.toNat < 2 ^ 32) : maskC c x = x := by
  cases c
  · exact maskW_of_lt x h
  · rfl

def env0 : SymEnv := ⟨fun _ _ => 0, fun _ _ _ => 0, fun _ _ _ => 0, fun _ => 0⟩

/-- An arm of phi `P` whose value is the constant `x`. -/
def ArmConst (G : ValGraph) (vids : List Std.I32) (P : Phi) (x : BitVec 64) (a : PhiArm) : Prop :=
  AtomKnown G vids a.value ∧ ∀ env, maskC P.cls (atomSem G env vids a.value) = x

theorem armConst_extends {G G' : ValGraph} (hp : vg_extends G G') {vids : List Std.I32} {P : Phi}
    {x : BitVec 64} {a : PhiArm} (h : ArmConst G vids P x a) : ArmConst G' vids P x a :=
  ⟨atomKnown_extends hp h.1, fun env => by rw [atomSem_extends hp h.1]; exact h.2 env⟩

theorem phi_select_sound {vg : ValGraph} {f : Func} {vids : Pion.Array Std.I32} {b k : Std.I32}
    {q : Std.I32 × ValGraph} (h : phi_select vg f vids b k = ok q) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (0 ≤ q.1.val → ∃ B P, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k.val.toNat]? = some P ∧
        SelOK q.2 f vids.val b P q.1) := by
  unfold phi_select at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨P, hP, h⟩ := bind_eq_ok h
  obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  have hPk : B.phis.val[k.val.toNat]? = some P := by rw [List.getElem?_eq_getElem hPl, hPv]
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd, fun h => by simp at h⟩
  rename_i hn2'
  have hlen2 : P.arms.val.length = 2 := by
    have : n = 2#i32 := i32_ext (by simpa using hn2')
    subst this; simp at hn1; omega
  obtain ⟨B3, hB3, h⟩ := bind_eq_ok h
  rw [hB] at hB3; cases ok_inj' hB3
  obtain ⟨P3, hP3, h⟩ := bind_eq_ok h
  rw [hP] at hP3; cases ok_inj' hP3
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  unfold phi_select_loop0 at hs
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph × Std.I32 × Std.I32) =>
      match x with | (j, vg, p1, p0) => phi_select_loop0.body f b k vids P.cls j vg p1 p0)
    (fun x => 0 ≤ x.1.val ∧ x.1.val ≤ 2 ∧ vg_extends vg x.2.1 ∧ ValGraphDAG x.2.1 ∧
      (0 ≤ x.2.2.1.val → ∃ a ∈ P.arms.val, a.pred = x.2.2.1 ∧ ArmConst x.2.1 vids.val P 1 a) ∧
      (0 ≤ x.2.2.2.val → ∃ a ∈ P.arms.val, a.pred = x.2.2.2 ∧ ArmConst x.2.1 vids.val P 0 a))
    (fun r => match r with
      | .inl e => vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ e.1 = (-2)#i32
      | .inr y => vg_extends vg y.2.1 ∧ ValGraphDAG y.2.1 ∧
          (0 ≤ y.2.2.1.val → ∃ a ∈ P.arms.val, a.pred = y.2.2.1 ∧ ArmConst y.2.1 vids.val P 1 a) ∧
          (0 ≤ y.2.2.2.val → ∃ a ∈ P.arms.val, a.pred = y.2.2.2 ∧ ArmConst y.2.1 vids.val P 0 a))
    ?_ _ _ hs ⟨by simp, by simp, vg_extends_refl _, hd, fun h => by simp at h, fun h => by simp at h⟩
  rotate_left
  · rintro ⟨jI, vgj, p1, p0⟩ c ⟨hj0, hj2, hej, hdj, h1, h0⟩ hc
    try dsimp only at hj0 hj2 hej hdj h1 h0 hc
    unfold phi_select_loop0.body at hc
    split at hc
    · rename_i hlt
      have h2 : (2#i32 : Std.I32).val = 2 := by decide
      have hlt' : jI.val < 2 := by simpa [i32_lt_iff, h2] using hlt
      have hjs : (Pion.I32.add jI 1#i32).val = jI.val + 1 := i32_succ_val (n := 2#i32) (by simpa [i32_lt_iff] using hlt)
      obtain ⟨B4, hB4, hc⟩ := bind_eq_ok hc
      rw [hB] at hB4; cases ok_inj' hB4
      obtain ⟨P4, hP4, hc⟩ := bind_eq_ok hc
      rw [hP] at hP4; cases ok_inj' hP4
      obtain ⟨A, hA, hc⟩ := bind_eq_ok hc
      obtain ⟨_, hAl, hAv⟩ := arr_get_ok hA
      have hAm : A ∈ P.arms.val := by rw [← hAv]; exact List.getElem_mem _
      obtain ⟨B5, hB5, hc⟩ := bind_eq_ok hc
      rw [hB] at hB5; cases ok_inj' hB5
      obtain ⟨P5, hP5, hc⟩ := bind_eq_ok hc
      rw [hP] at hP5; cases ok_inj' hP5
      obtain ⟨A2, hA2, hc⟩ := bind_eq_ok hc
      rw [hA] at hA2; cases ok_inj' hA2
      obtain ⟨t11, ht11, hc⟩ := bind_eq_ok hc
      split at hc
      · rw [← ok_inj' hc]; exact ⟨hej, hdj, rfl⟩
      rename_i ht11'
      have ht11t : t11 = true := by simpa using ht11'
      subst ht11t
      obtain ⟨q1, hq1, hc⟩ := bind_eq_ok hc
      obtain ⟨av, vg1⟩ := q1
      try simp only [uncurry_apply_pair] at hc
      have hvj : VidsOK vgj vids.val := vidsOK_extends hej hv
      obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hdj hvj
      dsimp only at e1 d1 h1u
      have hav0 : 0 ≤ av.val := atom_use_valid hq1 hdj hvj (atom_known_true ht11)
      obtain ⟨vav, -, vk, vs⟩ := h1u hav0
      have hconst : ∀ (x : Std.U64), vg_is_const vg1 av x = ok true → ArmConst vg1 vids.val P x.bv A := by
        intro x hx
        obtain ⟨hcx, -⟩ := vg_is_const_true hx
        refine ⟨atomKnown_extends e1 vk, fun env => ?_⟩
        rw [atomSem_extends e1 vk, ← vs env]
        exact constOf_evI d1 env hcx
      obtain ⟨t14, ht14, hc⟩ := bind_eq_ok hc
      obtain ⟨q2, hq2, hc⟩ := bind_eq_ok hc
      obtain ⟨p11, p01⟩ := q2
      rw [← ok_inj' hc]
      dsimp only
      refine ⟨by omega, by omega, vg_extends_trans hej e1, d1, ?_, ?_⟩
      · intro hp
        split at hq2
        · rename_i h14
          cases ok_inj' hq2
          exact ⟨A, hAm, rfl, hconst _ (h14 ▸ ht14)⟩
        · obtain ⟨t15, ht15, hq2⟩ := bind_eq_ok hq2
          split at hq2
          · cases ok_inj' hq2
            obtain ⟨a, ha, hap, hac⟩ := h1 hp
            exact ⟨a, ha, hap, armConst_extends e1 hac⟩
          · cases ok_inj' hq2
            obtain ⟨a, ha, hap, hac⟩ := h1 hp
            exact ⟨a, ha, hap, armConst_extends e1 hac⟩
      · intro hp
        split at hq2
        · cases ok_inj' hq2
          obtain ⟨a, ha, hap, hac⟩ := h0 hp
          exact ⟨a, ha, hap, armConst_extends e1 hac⟩
        · obtain ⟨t15, ht15, hq2⟩ := bind_eq_ok hq2
          split at hq2
          · rename_i h15
            cases ok_inj' hq2
            exact ⟨A, hAm, rfl, hconst _ (h15 ▸ ht15)⟩
          · cases ok_inj' hq2
            obtain ⟨a, ha, hap, hac⟩ := h0 hp
            exact ⟨a, ha, hap, armConst_extends e1 hac⟩
    · rw [← ok_inj' hc]
      exact ⟨hej, hdj, h1, h0⟩
  cases s with
  | inl e =>
    simp only at h
    rw [← ok_inj' h]
    obtain ⟨e1, d1, he⟩ := key
    exact ⟨e1, d1, fun hq => by rw [he] at hq; simp at hq⟩
  | inr y =>
    obtain ⟨j1, vg1, p1, p0⟩ := y
    obtain ⟨e1, d1, hp1, hp0⟩ := key
    dsimp only at hp1 hp0
    try simp only at h
    have fail : ∀ g, vg_extends vg1 g → ValGraphDAG g → ∀ (r : Std.I32), ok ((-1)#i32, g) = ok q →
        vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (0 ≤ q.1.val → ∃ B P, f.blocks.val[b.val.toNat]? = some B ∧
          B.phis.val[k.val.toNat]? = some P ∧ SelOK q.2 f vids.val b P q.1) := by
      intro g eg dg _ hq
      rw [← ok_inj' hq]
      exact ⟨vg_extends_trans e1 eg, dg, fun h => by simp at h⟩
    split at h
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    rename_i hpp
    simp only [Bool.or_eq_true, decide_eq_true_eq, beq_iff_eq, not_or, not_lt] at hpp
    obtain ⟨⟨hp10, hp00⟩, hpne⟩ := hpp
    have hp10' : 0 ≤ p1.val := by simpa [i32_le_iff] using hp10
    have hp00' : 0 ≤ p0.val := by simpa [i32_le_iff] using hp00
    obtain ⟨a1, ha1, ha1p, ha1c⟩ := hp1 hp10'
    obtain ⟨a0, ha0, ha0p, ha0c⟩ := hp0 hp00'
    obtain ⟨B1, hB1, h⟩ := bind_eq_ok h
    split at h
    rotate_left
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    rename_i s1 _
    split at h
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    obtain ⟨B0, hB0, h⟩ := bind_eq_ok h
    split at h
    rotate_left
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    split at h
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    obtain ⟨d, hdd, h⟩ := bind_eq_ok h
    obtain ⟨t22, ht22, h⟩ := bind_eq_ok h
    split at h
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    rename_i h22
    have hd0 : 0 ≤ d.val ∧ ∃ d2, sole_pred f p0 = ok d2 ∧ d = d2 := by
      split at ht22
      · cases ok_inj' ht22; exact absurd rfl h22
      · rename_i hdn
        obtain ⟨d2, hd2, ht22⟩ := bind_eq_ok ht22
        cases ok_inj' ht22
        refine ⟨by simpa [i32_lt_iff] using hdn, d2, hd2, ?_⟩
        exact i32_ext (by simpa using h22)
    obtain ⟨hd0, d2, hd2, rfl⟩ := hd0
    obtain ⟨-, -, hsole1⟩ := sole_pred_sound hdd hd0
    obtain ⟨-, -, hsole0⟩ := sole_pred_sound hd2 hd0
    obtain ⟨Bd, hBd, h⟩ := bind_eq_ok h
    obtain ⟨_, hBdl, hBdv⟩ := arr_get_ok hBd
    split at h
    rotate_left
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    rename_i cond s1' s2' hterm
    split at h
    · exact fail vg1 (vg_extends_refl _) d1 0#i32 h
    rename_i hss
    simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, not_not] at hss
    obtain ⟨hs1', hs2'⟩ := hss
    have hs1'' := hs1'.symm
    have hs2'' := hs2'.symm
    subst hs1'' hs2''
    obtain ⟨t26, ht26, h⟩ := bind_eq_ok h
    split at h
    · cases ok_inj' h; exact ⟨e1, d1, fun h => by simp at h⟩
    rename_i h26
    have h26t : t26 = true := by simpa using h26
    subst h26t
    obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
    obtain ⟨cv, vg2⟩ := q2
    try simp only [uncurry_apply_pair] at h
    have hv1 : VidsOK vg1 vids.val := vidsOK_extends e1 hv
    obtain ⟨e2, d2, h2u⟩ := atom_use_sound hq2 d1 hv1
    dsimp only at e2 d2 h2u
    have hcv0 : 0 ≤ cv.val := atom_use_valid hq2 d1 hv1 (atom_known_true ht26)
    obtain ⟨vcv, -, ck, cs⟩ := h2u hcv0
    obtain ⟨t29, ht29, h⟩ := bind_eq_ok h
    split at h
    · exact fail vg2 e2 d2 0#i32 h
    rename_i h29
    have h29t : t29 = true := by simpa using h29
    subst h29t
    have ht29' : fits_bits vg2 cv 1#i32 = ok true := by
      unfold is_bool_node at ht29
      obtain ⟨r, hr, e⟩ := bind_eq_ok ht29
      rw [hr, ok_inj' e]
    obtain ⟨-, -, hfit⟩ := fits_bits_sound vg2 d2 cv 1#i32 true ht29' rfl
    obtain ⟨q3, hq3, h⟩ := bind_eq_ok h
    obtain ⟨v, vg3⟩ := q3
    try simp only [uncurry_apply_pair] at h
    obtain ⟨e3, d3, vv, -, vval⟩ := vg_use_sound hq3 d2 vcv
    obtain ⟨t33, ht33, h⟩ := bind_eq_ok h
    obtain ⟨t35, ht35, h⟩ := bind_eq_ok h
    obtain ⟨t37, ht37, h⟩ := bind_eq_ok h
    split at h
    · exact fail vg3 (vg_extends_trans e2 e3) d3 0#i32 h
    rename_i h37
    have h37f : t37 = false := by simpa using h37
    subst h37f
    -- none of the three blocks is mentioned
    have hv0 : 0 ≤ v.val := vv.1
    have hm : vid_mentions_blk vg3 v b = ok false ∧ vid_mentions_blk vg3 v p1 = ok false ∧
        vid_mentions_blk vg3 v p0 = ok false := by
      split at ht37
      · cases ok_inj' ht37
      rename_i h35
      have h35f : t35 = false := by simpa using h35
      subst h35f
      split at ht35
      · cases ok_inj' ht35
      rename_i h33
      have h33f : t33 = false := by simpa using h33
      subst h33f
      split at ht33
      · cases ok_inj' ht33
      exact ⟨bind_id_ok ht33, bind_id_ok ht35, bind_id_ok ht37⟩
    cases ok_inj' h
    refine ⟨vg_extends_trans e1 (vg_extends_trans e2 e3), d3, fun _ => ⟨B, P, hBb, hPk, ?_⟩⟩
    have e13 := vg_extends_trans e2 e3
    -- the two arms are distinct, hence all of them
    have hne01 : a1 ≠ a0 := by
      rintro rfl
      have h1 := ha1c.2 env0
      rw [ha0c.2 env0] at h1
      exact absurd h1 (by decide)
    have harms : ∀ a ∈ P.arms.val, a = a1 ∨ a = a0 := by
      intro a ha
      obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ha
      obtain ⟨i1, hi1, rfl⟩ := List.getElem_of_mem ha1
      obtain ⟨i0, hi0, rfl⟩ := List.getElem_of_mem ha0
      have hii : i1 ≠ i0 := fun e => hne01 (by subst e; rfl)
      by_cases h1 : i = i1
      · subst h1; exact Or.inl rfl
      · by_cases h0 : i = i0
        · subst h0; exact Or.inr rfl
        · omega
    have hBdd : f.blocks.val[d.val.toNat]? = some Bd := by rw [List.getElem?_eq_getElem hBdl, hBdv]
    refine ⟨p1, p0, d, cond, fun e => hpne (by rw [e]), fun a ha => ?_, hd0, hsole1, hsole0,
      ⟨Bd, hBdd, hterm⟩, atomKnown_extends (vg_extends_trans e2 e3) ck,
      vv, fun env => ?_, fun x hx env env' he => ?_⟩
    · rcases harms a ha with rfl | rfl
      · exact Or.inl ⟨ha1p, (armConst_extends e13 ha1c).1, (armConst_extends e13 ha1c).2⟩
      · exact Or.inr ⟨ha0p, (armConst_extends e13 ha0c).1, (armConst_extends e13 ha0c).2⟩
    · have hv1 : evI vg3 env v = maskC P.cls (evI vg2 env cv) := vval env
      have hc2 : evI vg2 env cv = maskC .W (atomSem vg1 env vids.val cond) := cs env
      have hsem : atomSem vg3 env vids.val cond = atomSem vg1 env vids.val cond := atomSem_extends e13 ck env
      rw [hv1, hsem, ← hc2]
      have hlt := hfit env
      have hlt2 : (evI vg2 env cv).toNat < 2 := by simpa using hlt
      rw [maskC_small _ _ (by omega)]
      rcases (by omega : (evI vg2 env cv).toNat = 0 ∨ (evI vg2 env cv).toNat = 1) with h0 | h1
      · have : evI vg2 env cv = 0 := BitVec.eq_of_toNat_eq (by simpa using h0)
        simp [this]
      · have : evI vg2 env cv = 1 := BitVec.eq_of_toNat_eq (by simpa using h1)
        simp [this]
    · rcases hx with rfl | rfl | rfl
      · exact vid_mentions_blk_sound hm.1 hv0 he
      · exact vid_mentions_blk_sound hm.2.1 hv0 he
      · exact vid_mentions_blk_sound hm.2.2 hv0 he

/-! ## Phis with the same arguments -/

theorem phiArg_idx {P : Phi} {prev : Int} {ai : Nat} (hai : ai < P.arms.val.length)
    (hp : P.arms.val[ai].pred.val = prev)
    (hfirst : ∀ j < ai, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred.val ≠ prev) :
    phiArg P prev = some P.arms.val[ai].value := by
  unfold phiArg
  suffices h : P.arms.val.find? (fun a => decide (a.pred.val = prev)) = some P.arms.val[ai] by
    rw [h]; rfl
  rw [List.find?_eq_some_iff_getElem]
  refine ⟨by simp [hp], ai, hai, rfl, fun j hj => ?_⟩
  simp only [Bool.not_eq_true', decide_eq_false_iff_not]
  exact hfirst j hj (by omega)

/-- On the edge of arm `a2` of phi `P2`, phi `P1` takes the same value (or both are their own
temps). -/
def SameArm (G : ValGraph) (vids : List Std.I32) (P1 P2 : Phi) (a2 : PhiArm) : Prop :=
  ∃ a1, phiArg P1 a2.pred.val = some a1 ∧
    ((a1 = .Temp P1.dst ∧ a2.value = .Temp P2.dst) ∨
     (AtomKnown G vids a1 ∧ AtomKnown G vids a2.value ∧
       ∀ env, maskC P2.cls (atomSem G env vids a1) = maskC P2.cls (atomSem G env vids a2.value)))

theorem sameArm_extends {G G' : ValGraph} (hp : vg_extends G G') {vids : List Std.I32} {P1 P2 : Phi}
    {a2 : PhiArm} (h : SameArm G vids P1 P2 a2) : SameArm G' vids P1 P2 a2 := by
  obtain ⟨a1, ha1, hs | ⟨k1, k2, he⟩⟩ := h
  · exact ⟨a1, ha1, Or.inl hs⟩
  · exact ⟨a1, ha1, Or.inr ⟨atomKnown_extends hp k1, atomKnown_extends hp k2, fun env => by
      rw [atomSem_extends hp k1, atomSem_extends hp k2]; exact he env⟩⟩

theorem phis_same_args_sound {vg : ValGraph} {f : Func} {vids : Pion.Array Std.I32} {b k1 k2 : Std.I32}
    {q : Bool × ValGraph} (h : phis_same_args vg f vids b k1 k2 = ok q) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (q.1 = true → ∃ B P1 P2, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k1.val.toNat]? = some P1 ∧
        B.phis.val[k2.val.toNat]? = some P2 ∧ ∀ a2 ∈ P2.arms.val, SameArm q.2 vids.val P1 P2 a2) := by
  unfold phis_same_args at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨P2, hP2, h⟩ := bind_eq_ok h
  obtain ⟨_, hP2l, hP2v⟩ := arr_get_ok hP2
  have hP2k : B.phis.val[k2.val.toNat]? = some P2 := by rw [List.getElem?_eq_getElem hP2l, hP2v]
  obtain ⟨n2, hn2, h⟩ := bind_eq_ok h
  obtain ⟨hn21, hn22⟩ := arr_length_ok hn2
  obtain ⟨B3, hB3, h⟩ := bind_eq_ok h
  rw [hB] at hB3; cases ok_inj' hB3
  obtain ⟨P1, hP1, h⟩ := bind_eq_ok h
  obtain ⟨_, hP1l, hP1v⟩ := arr_get_ok hP1
  have hP1k : B.phis.val[k1.val.toNat]? = some P1 := by rw [List.getElem?_eq_getElem hP1l, hP1v]
  obtain ⟨n1, hn1, h⟩ := bind_eq_ok h
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd, fun h => by cases h⟩
  obtain ⟨B6, hB6, h⟩ := bind_eq_ok h
  rw [hB] at hB6; cases ok_inj' hB6
  obtain ⟨P6, hP6, h⟩ := bind_eq_ok h
  rw [hP2] at hP6; cases ok_inj' hP6
  obtain ⟨B8, hB8, h⟩ := bind_eq_ok h
  rw [hB] at hB8; cases ok_inj' hB8
  obtain ⟨P8, hP8, h⟩ := bind_eq_ok h
  rw [hP1] at hP8; cases ok_inj' hP8
  obtain ⟨B10, hB10, h⟩ := bind_eq_ok h
  rw [hB] at hB10; cases ok_inj' hB10
  obtain ⟨P10, hP10, h⟩ := bind_eq_ok h
  rw [hP2] at hP10; cases ok_inj' hP10
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  unfold phis_same_args_loop0 at hs
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (j, vg) => phis_same_args_loop0.body n2 f b k2 k1 P1.dst P2.dst vids P2.cls j vg)
    (fun x => 0 ≤ x.1.val ∧ vg_extends vg x.2 ∧ ValGraphDAG x.2 ∧
      ∀ j (hj : j < P2.arms.val.length), j < x.1.val.toNat → SameArm x.2 vids.val P1 P2 P2.arms.val[j])
    (fun r => match r with
      | .inl e => vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ e.1 = false
      | .inr y => vg_extends vg y.2 ∧ ValGraphDAG y.2 ∧ ∀ a2 ∈ P2.arms.val, SameArm y.2 vids.val P1 P2 a2)
    ?_ _ _ hs ⟨by simp, vg_extends_refl _, hd, fun j _ hj => by simp at hj⟩
  · cases s with
    | inl e =>
      simp only at h
      rw [← ok_inj' h]
      obtain ⟨e1, d1, he⟩ := key
      exact ⟨e1, d1, fun ht => by rw [he] at ht; cases ht⟩
    | inr y =>
      simp only at h
      rw [← ok_inj' h]
      obtain ⟨e1, d1, hall⟩ := key
      exact ⟨e1, d1, fun _ => ⟨B, P1, P2, hBb, hP1k, hP2k, hall⟩⟩
  rintro ⟨jI, vgj⟩ c ⟨hj0, hej, hdj, hall⟩ hc
  try dsimp only at hj0 hej hdj hall hc
  unfold phis_same_args_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : jI.val < P2.arms.val.length := by simpa [i32_lt_iff, hn21] using hlt
    have hjs := i32_succ_val' hlt' hn22
    obtain ⟨B4, hB4, hc⟩ := bind_eq_ok hc
    rw [hB] at hB4; cases ok_inj' hB4
    obtain ⟨P4, hP4, hc⟩ := bind_eq_ok hc
    rw [hP2] at hP4; cases ok_inj' hP4
    obtain ⟨A, hA, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hAl, hAv⟩ := arr_get_ok hA
    obtain ⟨B5, hB5, hc⟩ := bind_eq_ok hc
    rw [hB] at hB5; cases ok_inj' hB5
    obtain ⟨P5, hP5, hc⟩ := bind_eq_ok hc
    rw [hP2] at hP5; cases ok_inj' hP5
    obtain ⟨A2, hA2, hc⟩ := bind_eq_ok hc
    rw [hA] at hA2; cases ok_inj' hA2
    obtain ⟨j1, hj1, hc⟩ := bind_eq_ok hc
    split at hc
    · rw [← ok_inj' hc]; exact ⟨hej, hdj, rfl⟩
    rename_i hj1n
    have hj10 : 0 ≤ j1.val := by simpa [i32_lt_iff] using hj1n
    obtain ⟨B', P1', -, hB', -, hP1', hcase⟩ := phi_arm_index_spec hj1
    rw [hBb] at hB'; cases hB'
    rw [hP1k] at hP1'; cases hP1'
    obtain ⟨-, hj1l, hj1p, hj1f⟩ : 0 ≤ j1.val ∧ ∃ hr : j1.val.toNat < P1.arms.val.length,
        P1.arms.val[j1.val.toNat].pred = A.pred ∧
        ∀ j < j1.val.toNat, ∀ hj : j < P1.arms.val.length, P1.arms.val[j].pred ≠ A.pred := by
      rcases hcase with hc1 | ⟨hm, -⟩
      · exact hc1
      · omega
    have hphiarg : phiArg P1 A.pred.val = some P1.arms.val[j1.val.toNat].value :=
      phiArg_idx hj1l (by rw [hj1p]) (fun j hj hjl e => hj1f j hj hjl (i32_ext e))
    obtain ⟨B7, hB7, hc⟩ := bind_eq_ok hc
    rw [hB] at hB7; cases ok_inj' hB7
    obtain ⟨P7, hP7, hc⟩ := bind_eq_ok hc
    rw [hP1] at hP7; cases ok_inj' hP7
    obtain ⟨A1, hA1, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hA1l, hA1v⟩ := arr_get_ok hA1
    obtain ⟨t22, ht22, hc⟩ := bind_eq_ok hc
    obtain ⟨t24, ht24, hc⟩ := bind_eq_ok hc
    obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
    have hAj : P2.arms.val[jI.val.toNat] = A := hAv
    have hst : (∃ e, sres = .inl e ∧ vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ e.1 = false) ∨
        (∃ vg3, sres = .inr vg3 ∧ vg_extends vgj vg3 ∧ ValGraphDAG vg3 ∧ SameArm vg3 vids.val P1 P2 A) := by
      split at hsres
      · obtain ⟨q1, hq1, hsres⟩ := bind_eq_ok hsres
        obtain ⟨v1, vg1⟩ := q1
        try simp only [uncurry_apply_pair] at hsres
        obtain ⟨q2, hq2, hsres⟩ := bind_eq_ok hsres
        obtain ⟨v2, vg2⟩ := q2
        try simp only [uncurry_apply_pair] at hsres
        have hvj : VidsOK vgj vids.val := vidsOK_extends hej hv
        obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hdj hvj
        obtain ⟨e2, d2, h2u⟩ := atom_use_sound hq2 d1 (vidsOK_extends e1 hvj)
        dsimp only at e1 d1 h1u e2 d2 h2u
        split at hsres
        · cases ok_inj' hsres
          exact Or.inl ⟨_, rfl, vg_extends_trans hej (vg_extends_trans e1 e2), d2, rfl⟩
        rename_i hok
        simp only [Bool.or_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq, not_or, not_lt,
          not_not] at hok
        obtain ⟨⟨h10, h20⟩, h12⟩ := hok
        cases ok_inj' hsres
        have h10' : 0 ≤ v1.val := by simpa [i32_le_iff] using h10
        have h20' : 0 ≤ v2.val := by simpa [i32_le_iff] using h20
        obtain ⟨vv1, -, k1', s1⟩ := h1u h10'
        obtain ⟨vv2, -, k2', s2⟩ := h2u h20'
        subst h12
        refine Or.inr ⟨_, rfl, vg_extends_trans e1 e2, d2, ⟨_, hphiarg, Or.inr ⟨?_, ?_, fun env => ?_⟩⟩⟩
        · rw [← hA1v] at k1'; exact atomKnown_extends (vg_extends_trans e1 e2) k1'
        · exact atomKnown_extends e2 k2'
        · rw [← hA1v] at s1 k1'
          rw [atomSem_extends (vg_extends_trans e1 e2) k1', atomSem_extends e2 k2', ← s1 env, ← s2 env,
            extends_evI e2 env vv1]
      · rename_i h24
        cases ok_inj' hsres
        have h24t : t24 = true := by simpa using h24
        subst h24t
        split at ht24
        · rename_i h22
          have hs1 := (is_self_arm_spec ht22).1 h22
          obtain ⟨t23, ht23, e23⟩ := bind_eq_ok ht24
          have hs2 := (is_self_arm_spec ht23).1 (ok_inj' e23)
          rw [← hA1v] at hs1
          exact Or.inr ⟨_, rfl, vg_extends_refl _, hdj, ⟨_, hphiarg, Or.inl ⟨hs1, hs2⟩⟩⟩
        · cases ok_inj' ht24
    rcases hst with ⟨e, rfl, he1, he2, he3⟩ | ⟨vg3, rfl, h3e, h3d, h3a⟩
    · simp only at hc
      rw [← ok_inj' hc]
      exact ⟨he1, he2, he3⟩
    · simp only at hc
      rw [← ok_inj' hc]
      dsimp only
      refine ⟨by omega, vg_extends_trans hej h3e, h3d, fun j hj hjl => ?_⟩
      by_cases hjj : j = jI.val.toNat
      · subst hjj; rw [hAj]; exact h3a
      · exact sameArm_extends h3e (hall j hj (by omega))
  · rename_i hge
    have hge' : P2.arms.val.length ≤ jI.val := by simpa [i32_lt_iff, hn21] using hge
    rw [← ok_inj' hc]
    refine ⟨hej, hdj, fun a ha => ?_⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem ha
    exact hall j hj (by omega)

/-! ## Phi definitions of the source -/

/-- `v`, the symbolic value of the destination of phi `k` (`P`) of block `b` (`B`): its leaf, a
folded value, a 0/1 select, or the value of an earlier phi with the same arguments. -/
def PhiDef (G : ValGraph) (f : Func) (info : FnInfo) (vids : List Std.I32) (facts : List Fact)
    (b k : Std.I32) (B : Block) (P : Phi) (v : Std.I32) : Prop :=
  Valid G v ∧
  (nodeAt G v = some (.SPhi P.cls b k) ∨
   ((∀ env env', AgreeExcept b env env' → evI G env' v = evI G env v) ∧
     (∀ env, maskC P.cls (evI G env v) = evI G env v) ∧
     ∀ a ∈ P.arms.val, FoldArm G f info vids facts b P v a) ∨
   SelOK G f vids b P v ∨
   ∃ k1 < k.val.toNat, ∃ P1, B.phis.val[k1]? = some P1 ∧ P1.cls = P.cls ∧
     vids[P1.dst.val.toNat]? = some v ∧ 0 ≤ P1.dst.val ∧ ∀ a2 ∈ P.arms.val, SameArm G vids P1 P a2)

theorem phiDef_extends {G G' : ValGraph} (hp : vg_extends G G') {f : Func} {info : FnInfo}
    {vids : List Std.I32} {facts : List Fact} {b k : Std.I32} {B : Block} {P : Phi} {v : Std.I32}
    (h : PhiDef G f info vids facts b k B P v) : PhiDef G' f info vids facts b k B P v := by
  obtain ⟨hv, h⟩ := h
  refine ⟨extends_valid hp hv, ?_⟩
  rcases h with h | ⟨hs, hm, ha⟩ | h | ⟨k1, hk1, P1, h1, h2, h3, h4, h5⟩
  · left; rw [extends_nodeAt hp hv]; exact h
  · right; left
    exact ⟨fun env env' he => by rw [extends_evI hp env hv, extends_evI hp env' hv]; exact hs env env' he,
      (mask_ext hp ⟨hv, hm⟩).2, fun a ha' => foldArm_extends hp (ha a ha')⟩
  · right; right; left; exact selOK_extends hp h
  · right; right; right; exact ⟨k1, hk1, P1, h1, h2, h3, h4, fun a2 h => sameArm_extends hp (h5 a2 h)⟩

theorem src_phi_def_ok_sound {vg : ValGraph} {f : Func} {info : FnInfo} {svid : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {b k : Std.I32} {q : Bool × ValGraph}
    (h : src_phi_def_ok vg f info svid facts b k = ok q) (hd : ValGraphDAG vg) (hv : VidsOK vg svid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (q.1 = true → ∃ B P v, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k.val.toNat]? = some P ∧
        svid.val[P.dst.val.toNat]? = some v ∧ 0 ≤ P.dst.val ∧
        PhiDef q.2 f info svid.val facts.val b k B P v) := by
  unfold src_phi_def_ok at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨P, hP, h⟩ := bind_eq_ok h
  obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
  have hPk : B.phis.val[k.val.toNat]? = some P := by rw [List.getElem?_eq_getElem hPl, hPv]
  obtain ⟨B2, hB2, h⟩ := bind_eq_ok h
  rw [hB] at hB2; cases ok_inj' hB2
  obtain ⟨P2, hP2, h⟩ := bind_eq_ok h
  rw [hP] at hP2; cases ok_inj' hP2
  obtain ⟨v, hvg, h⟩ := bind_eq_ok h
  obtain ⟨hd0, hvl, hvv⟩ := arr_get_ok hvg
  have hsv : svid.val[P.dst.val.toNat]? = some v := by rw [List.getElem?_eq_getElem hvl, hvv]
  obtain ⟨t5, ht5, h⟩ := bind_eq_ok h
  obtain ⟨ht51, -⟩ := vg_valid_ok ht5
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd, fun h => by cases h⟩
  rename_i h5
  have hvalid : Valid vg v := ht51.1 (by simpa using h5)
  obtain ⟨node, hnode, h⟩ := bind_eq_ok h
  obtain ⟨_, hnl, hnv⟩ := arr_get_ok hnode
  have hnodeAt : nodeAt vg v = some node := by
    simp only [nodeAt, hvalid.1, ↓reduceIte]; rw [List.getElem?_eq_getElem hnl, hnv]
  obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
  have good : ∀ g, vg_extends vg g → ValGraphDAG g → ∀ (r : Bool),
      (r = true → PhiDef g f info svid.val facts.val b k B P v) → ok (r, g) = ok q →
      vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
        (q.1 = true → ∃ B P v, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k.val.toNat]? = some P ∧
          svid.val[P.dst.val.toNat]? = some v ∧ 0 ≤ P.dst.val ∧
          PhiDef q.2 f info svid.val facts.val b k B P v) := by
    intro g eg dg r hr hq
    rw [← ok_inj' hq]
    exact ⟨eg, dg, fun ht => ⟨B, P, v, hBb, hPk, hsv, hd0, hr ht⟩⟩
  split at h
  · rename_i h7
    have e := (sym_node_eq_ok ht7).1 h7
    rw [e] at hnodeAt
    exact good vg (vg_extends_refl _) hd true (fun _ => ⟨hvalid, Or.inl hnodeAt⟩) h
  obtain ⟨q9, hq9, h⟩ := bind_eq_ok h
  obtain ⟨t9, vg1⟩ := q9
  try simp only [uncurry_apply_pair] at h
  obtain ⟨e1, d1, hf1⟩ := phi_fold_sound hq9 hd hv
  dsimp only at e1 d1 hf1
  split at h
  · rename_i h9
    rw [h9] at hf1
    refine good vg1 e1 d1 true (fun _ => ?_) h
    obtain ⟨B', P', hB', hP', hval, hmask, hmen, harms⟩ := hf1 hvalid.1
    rw [hBb] at hB'; cases hB'
    rw [hPk] at hP'; cases hP'
    exact ⟨hval, Or.inr (Or.inl ⟨fun env env' he => vid_mentions_blk_sound hmen hvalid.1 he, hmask, harms⟩)⟩
  obtain ⟨q11, hq11, h⟩ := bind_eq_ok h
  obtain ⟨t11, vg2⟩ := q11
  try simp only [uncurry_apply_pair] at h
  obtain ⟨e2, d2, hs2⟩ := phi_select_sound hq11 d1 (vidsOK_extends e1 hv)
  dsimp only at e2 d2 hs2
  split at h
  · rename_i h11
    rw [h11] at hs2
    refine good vg2 (vg_extends_trans e1 e2) d2 true (fun _ => ?_) h
    obtain ⟨B', P', hB', hP', hsel⟩ := hs2 hvalid.1
    rw [hBb] at hB'; cases hB'
    rw [hPk] at hP'; cases hP'
    exact ⟨extends_valid (vg_extends_trans e1 e2) hvalid, Or.inr (Or.inr (Or.inl hsel))⟩
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  unfold src_phi_def_ok_loop0 at hs
  have hk0 : 0 ≤ k.val := by
    have := (arr_get_ok hP).1; exact this
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (k1, vg) => src_phi_def_ok_loop0.body k f b P.cls svid v k1 vg)
    (fun x => 0 ≤ x.1.val ∧ vg_extends vg2 x.2 ∧ ValGraphDAG x.2)
    (fun r => match r with
      | .inl e => vg_extends vg2 e.2 ∧ ValGraphDAG e.2 ∧
          (e.1 = true → ∃ k1 < k.val.toNat, ∃ P1, B.phis.val[k1]? = some P1 ∧ P1.cls = P.cls ∧
            svid.val[P1.dst.val.toNat]? = some v ∧ 0 ≤ P1.dst.val ∧
            ∀ a2 ∈ P.arms.val, SameArm e.2 svid.val P1 P a2)
      | .inr y => vg_extends vg2 y.2 ∧ ValGraphDAG y.2)
    ?_ _ _ hs ⟨by simp, vg_extends_refl _, d2⟩
  · have e12 := vg_extends_trans e1 e2
    cases s with
    | inl r =>
      simp only at h
      obtain ⟨e3, d3, hr⟩ := key
      refine good r.2 (vg_extends_trans e12 e3) d3 r.1 (fun ht => ?_) (by rw [← h])
      exact ⟨extends_valid (vg_extends_trans e12 e3) hvalid, Or.inr (Or.inr (Or.inr (hr ht)))⟩
    | inr y =>
      simp only at h
      obtain ⟨e3, d3⟩ := key
      exact good y.2 (vg_extends_trans e12 e3) d3 false (fun hf => by cases hf) h
  rintro ⟨k1, vgk⟩ c ⟨hk10, hek, hdk⟩ hc
  try dsimp only at hk10 hek hdk hc
  unfold src_phi_def_ok_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : k1.val < k.val := by simpa [i32_lt_iff] using hlt
    have hks : (Pion.I32.add k1 1#i32).val = k1.val + 1 := i32_succ_val hlt
    obtain ⟨B3, hB3, hc⟩ := bind_eq_ok hc
    rw [hB] at hB3; cases ok_inj' hB3
    obtain ⟨P1, hP1, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hP1l, hP1v⟩ := arr_get_ok hP1
    have hP1k : B.phis.val[k1.val.toNat]? = some P1 := by rw [List.getElem?_eq_getElem hP1l, hP1v]
    obtain ⟨B4, hB4, hc⟩ := bind_eq_ok hc
    rw [hB] at hB4; cases ok_inj' hB4
    obtain ⟨P4, hP4, hc⟩ := bind_eq_ok hc
    rw [hP1] at hP4; cases ok_inj' hP4
    obtain ⟨t17, ht17, hc⟩ := bind_eq_ok hc
    obtain ⟨q20, hq20, hc⟩ := bind_eq_ok hc
    obtain ⟨t20, vg5⟩ := q20
    try simp only [uncurry_apply_pair] at hc
    have hvk : VidsOK vgk svid.val := vidsOK_extends (vg_extends_trans (vg_extends_trans e1 e2) hek) hv
    have h20 : vg_extends vgk vg5 ∧ ValGraphDAG vg5 ∧ (t20 = true → P1.cls = P.cls ∧
        svid.val[P1.dst.val.toNat]? = some v ∧ 0 ≤ P1.dst.val ∧
        ∀ a2 ∈ P.arms.val, SameArm vg5 svid.val P1 P a2) := by
      split at hq20
      · rename_i h17
        subst h17
        obtain ⟨e5, d5, h5⟩ := phis_same_args_sound (pair_ok hq20) hdk hvk
        dsimp only at e5 d5 h5
        refine ⟨e5, d5, fun ht => ?_⟩
        obtain ⟨B', P1', P', hB', hP1', hP', hsame⟩ := h5 ht
        rw [hBb] at hB'; cases hB'
        rw [hP1k] at hP1'; cases hP1'
        rw [hPk] at hP'; cases hP'
        split at ht17
        · rename_i hcls
          obtain ⟨w, hw, ht17⟩ := bind_eq_ok ht17
          obtain ⟨hw0, hwl, hwv⟩ := arr_get_ok hw
          have hwv' : w = v := by simpa using ok_inj' ht17
          subst hwv'
          exact ⟨by simpa using hcls, by rw [List.getElem?_eq_getElem hwl, hwv], hw0, hsame⟩
        · cases ok_inj' ht17
      · cases ok_inj' hq20
        exact ⟨vg_extends_refl _, hdk, fun h => by cases h⟩
    obtain ⟨e5, d5, h5⟩ := h20
    split at hc
    · rename_i ht20
      rw [← ok_inj' hc]
      obtain ⟨a1, a2, a3, a4⟩ := h5 ht20
      exact ⟨vg_extends_trans hek e5, d5, fun _ => ⟨k1.val.toNat, by omega, P1, hP1k, a1, a2, a3, a4⟩⟩
    · rw [← ok_inj' hc]
      dsimp only
      exact ⟨by omega, vg_extends_trans hek e5, d5⟩
  · rw [← ok_inj' hc]
    exact ⟨hek, hdk⟩

/-- What `check_src_defs` certifies of block `b`, in graph `g`. -/
def SrcDefsBlk (g : ValGraph) (f : Func) (info : FnInfo) (svid : List Std.I32) (facts : List Fact)
    (b : Std.I32) : Prop :=
  ∀ (B : Block), f.blocks.val[b.val.toNat]? = some B →
    (B.phis.val.length ≤ 2147483647 ∧ B.insts.val.length ≤ 2147483647) ∧
    (∀ (k : Std.I32) (P : Phi), 0 ≤ k.val → B.phis.val[k.val.toNat]? = some P →
      0 ≤ P.dst.val ∧ ∃ v, svid[P.dst.val.toNat]? = some v ∧ PhiDef g f info svid facts b k B P v) ∧
    (∀ (i : Std.I32) (hi0 : 0 ≤ i.val) (hi : i.val.toNat < B.insts.val.length),
      0 ≤ (instDst B.insts.val[i.val.toNat]).val →
      ∃ v, svid[(instDst B.insts.val[i.val.toNat]).val.toNat]? = some v ∧ Valid g v ∧
        (PureDef g svid B.insts.val[i.val.toNat] v ∨ (LeafInst B.insts.val[i.val.toNat] ∧
          nodeAt g v = some (.SEffect (effCls B.insts.val[i.val.toNat]) b i))))

theorem srcDefsBlk_extends {g g' : ValGraph} (hp : vg_extends g g') {f : Func} {info : FnInfo}
    {svid : List Std.I32} {facts : List Fact} {b : Std.I32} (h : SrcDefsBlk g f info svid facts b) :
    SrcDefsBlk g' f info svid facts b := by
  intro B hB
  obtain ⟨hl, hp1, hp2⟩ := h B hB
  refine ⟨hl, fun k P hk hP => ?_, fun i hi0 hi hd => ?_⟩
  · obtain ⟨a, v, hv, hdef⟩ := hp1 k P hk hP
    exact ⟨a, v, hv, phiDef_extends hp hdef⟩
  · obtain ⟨v, hv, hvv, hc⟩ := hp2 i hi0 hi hd
    refine ⟨v, hv, extends_valid hp hvv, ?_⟩
    rcases hc with hc | hc
    · exact Or.inl (pureDef_extends hp hvv hc)
    · exact Or.inr ⟨hc.1, by rw [extends_nodeAt hp hvv]; exact hc.2⟩

theorem check_src_defs_sound {vg : ValGraph} {f : Func} {info : FnInfo} {svid : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {q : Bool × ValGraph} (h : check_src_defs vg f info svid facts = ok q)
    (ht : q.1 = true) (hd : ValGraphDAG vg) (hinfo : InfoOK f info) (hv : VidsOK vg svid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      ∀ b : Std.I32, 0 ≤ b.val → SrcDefsBlk q.2 f info svid.val facts.val b := by
  have hnb := hinfo.nb
  have hlenle : f.blocks.val.length ≤ 2147483647 := by have := i32_val_le info.nb; omega
  unfold check_src_defs at h
  obtain ⟨s0, hs0, h⟩ := bind_eq_ok h
  unfold check_src_defs_loop0 at hs0
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (b, vg) => check_src_defs_loop0.body info f svid facts b vg)
    (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vg x.2 ∧ ValGraphDAG x.2 ∧
      ∀ b : Std.I32, 0 ≤ b.val → b.val < x.1.val → SrcDefsBlk x.2 f info svid.val facts.val b)
    (fun r => match r with
      | .inl e => e.1 = false
      | .inr y => vg_extends vg y.2 ∧ ValGraphDAG y.2 ∧
          ∀ b : Std.I32, 0 ≤ b.val → b.val < f.blocks.val.length → SrcDefsBlk y.2 f info svid.val facts.val b)
    ?_ _ _ hs0 ⟨by simp, vg_extends_refl _, hd, fun b hb hb' => by simp at hb'; omega⟩
  · cases s0 with
    | inl e =>
      simp only at h
      cases ok_inj' h
      simp only at ht key
      rw [ht] at key
      cases key
    | inr y =>
      obtain ⟨b1, vg1⟩ := y
      simp only at h
      cases ok_inj' h
      obtain ⟨e1, d1, hall⟩ := key
      refine ⟨e1, d1, fun b hb B hB => ?_⟩
      have hbl : b.val < f.blocks.val.length := by
        by_contra hc; rw [List.getElem?_eq_none (by omega)] at hB; cases hB
      exact hall b hb hbl B hB
  rintro ⟨bI, vgb⟩ c ⟨hb0, heb, hdb, hallb⟩ hc
  try dsimp only at hb0 heb hdb hallb hc
  unfold check_src_defs_loop0.body at hc
  split at hc
  · rename_i hlt
    have hlt' : bI.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb] using hlt
    have hbs := i32_succ_val' hlt' hlenle
    obtain ⟨B, hB, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
    have hBb : f.blocks.val[bI.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
    obtain ⟨np, hnp, hc⟩ := bind_eq_ok hc
    obtain ⟨hnp1, hnp2⟩ := arr_length_ok hnp
    obtain ⟨s1, hs1, hc⟩ := bind_eq_ok hc
    unfold check_src_defs_loop1 at hs1
    -- the phis
    have key1 := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
        match x with | (k, vg) => check_src_defs_loop1.body np f info svid facts bI k vg)
      (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vgb x.2 ∧ ValGraphDAG x.2 ∧
        ∀ (k : Std.I32) (P : Phi), 0 ≤ k.val → k.val < x.1.val → B.phis.val[k.val.toNat]? = some P →
          0 ≤ P.dst.val ∧ ∃ v, svid.val[P.dst.val.toNat]? = some v ∧
            PhiDef x.2 f info svid.val facts.val bI k B P v)
      (fun r => match r with
        | .inl e => e.1 = false
        | .inr y => vg_extends vgb y.2 ∧ ValGraphDAG y.2 ∧
            ∀ (k : Std.I32) (P : Phi), 0 ≤ k.val → B.phis.val[k.val.toNat]? = some P →
              0 ≤ P.dst.val ∧ ∃ v, svid.val[P.dst.val.toNat]? = some v ∧
                PhiDef y.2 f info svid.val facts.val bI k B P v)
      ?_ _ _ hs1 ⟨by simp, vg_extends_refl _, hdb, fun k P _ hk => by simp at hk; omega⟩
    rotate_left
    · rintro ⟨kI, vgk⟩ c ⟨hk0, hek, hdk, hallk⟩ hc
      try dsimp only at hk0 hek hdk hallk hc
      unfold check_src_defs_loop1.body at hc
      split at hc
      · rename_i hklt
        have hklt' : kI.val < B.phis.val.length := by simpa [i32_lt_iff, hnp1] using hklt
        have hks := i32_succ_val' hklt' hnp2
        obtain ⟨q3, hq3, hc⟩ := bind_eq_ok hc
        obtain ⟨t3, vg1⟩ := q3
        try simp only [uncurry_apply_pair] at hc
        obtain ⟨e1, d1, h1⟩ := src_phi_def_ok_sound hq3 hdk
          (vidsOK_extends (vg_extends_trans heb hek) hv)
        dsimp only at e1 d1 h1
        split at hc
        · rw [← ok_inj' hc]
        · rename_i h3
          rw [← ok_inj' hc]
          dsimp only
          obtain ⟨B', P', v', hB', hP', hsv, hd0, hdef⟩ := h1 (by simpa using h3)
          rw [hBb] at hB'; cases hB'
          refine ⟨by omega, vg_extends_trans hek e1, d1, fun k P hk hkl hP => ?_⟩
          by_cases hkk : k = kI
          · subst hkk
            rw [hP'] at hP; cases hP
            exact ⟨hd0, v', hsv, hdef⟩
          · obtain ⟨a, v, hv1, hdef1⟩ := hallk k P hk (by
              have : k.val ≠ kI.val := fun e => hkk (i32_ext e)
              omega) hP
            exact ⟨a, v, hv1, phiDef_extends e1 hdef1⟩
      · rename_i hkge
        have hkge' : B.phis.val.length ≤ kI.val := by simpa [i32_lt_iff, hnp1] using hkge
        rw [← ok_inj' hc]
        refine ⟨hek, hdk, fun k P hk hP => hallk k P hk ?_ hP⟩
        have : k.val.toNat < B.phis.val.length := by
          by_contra hc; rw [List.getElem?_eq_none (by omega)] at hP; cases hP
        omega
    cases s1 with
    | inl e =>
      simp only at hc
      rw [← ok_inj' hc]
      exact key1
    | inr y =>
      obtain ⟨k1, vg1⟩ := y
      simp only at hc
      obtain ⟨e1, d1, hphis⟩ := key1
      obtain ⟨B2, hB2, hc⟩ := bind_eq_ok hc
      rw [hB] at hB2; cases ok_inj' hB2
      obtain ⟨ni, hni, hc⟩ := bind_eq_ok hc
      obtain ⟨hni1, hni2⟩ := arr_length_ok hni
      obtain ⟨s2, hs2, hc⟩ := bind_eq_ok hc
      unfold check_src_defs_loop2 at hs2
      have key2 := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
          match x with | (i, vg) => check_src_defs_loop2.body ni f bI svid i vg)
        (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vg1 x.2 ∧ ValGraphDAG x.2 ∧
          ∀ (i : Std.I32) (hi0 : 0 ≤ i.val) (hi : i.val.toNat < B.insts.val.length), i.val < x.1.val →
            0 ≤ (instDst B.insts.val[i.val.toNat]).val →
            ∃ v, svid.val[(instDst B.insts.val[i.val.toNat]).val.toNat]? = some v ∧ Valid x.2 v ∧
              (PureDef x.2 svid.val B.insts.val[i.val.toNat] v ∨ (LeafInst B.insts.val[i.val.toNat] ∧
                nodeAt x.2 v = some (.SEffect (effCls B.insts.val[i.val.toNat]) bI i))))
        (fun r => match r with
          | .inl e => e.1 = false
          | .inr y => vg_extends vg1 y.2 ∧ ValGraphDAG y.2 ∧
              ∀ (i : Std.I32) (hi0 : 0 ≤ i.val) (hi : i.val.toNat < B.insts.val.length),
              0 ≤ (instDst B.insts.val[i.val.toNat]).val →
              ∃ v, svid.val[(instDst B.insts.val[i.val.toNat]).val.toNat]? = some v ∧ Valid y.2 v ∧
                (PureDef y.2 svid.val B.insts.val[i.val.toNat] v ∨ (LeafInst B.insts.val[i.val.toNat] ∧
                  nodeAt y.2 v = some (.SEffect (effCls B.insts.val[i.val.toNat]) bI i))))
        ?_ _ _ hs2 ⟨by simp, vg_extends_refl _, d1, fun i hi0 _ hi' => by simp at hi'; omega⟩
      rotate_left
      · rintro ⟨iI, vgi⟩ c ⟨hi0, hei, hdi, halli⟩ hc
        try dsimp only at hi0 hei hdi halli hc
        unfold check_src_defs_loop2.body at hc
        split at hc
        · rename_i hilt
          have hilt' : iI.val < B.insts.val.length := by simpa [i32_lt_iff, hni1] using hilt
          have his := i32_succ_val' hilt' hni2
          obtain ⟨B3, hB3, hc⟩ := bind_eq_ok hc
          rw [hB] at hB3; cases ok_inj' hB3
          obtain ⟨inst, hinst, hc⟩ := bind_eq_ok hc
          obtain ⟨_, hil, hiv⟩ := arr_get_ok hinst
          simp only [inst_dst_spec, bind_ok] at hc
          obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
          have hstep : ∀ vg3, sres = .inr vg3 → vg_extends vgi vg3 ∧ ValGraphDAG vg3 ∧
              (0 ≤ (instDst inst).val → ∃ v, svid.val[(instDst inst).val.toNat]? = some v ∧ Valid vg3 v ∧
                (PureDef vg3 svid.val inst v ∨ (LeafInst inst ∧ nodeAt vg3 v = some (.SEffect (effCls inst) bI iI)))) := by
            intro vg3 hs3
            subst hs3
            split at hsres
            · rename_i hd0
              obtain ⟨v, hv1, hsres⟩ := bind_eq_ok hsres
              obtain ⟨_, hvl, hvv⟩ := arr_get_ok hv1
              obtain ⟨q15, hq15, hsres⟩ := bind_eq_ok hsres
              obtain ⟨t15, vg5⟩ := q15
              try simp only [uncurry_apply_pair] at hsres
              split at hsres
              · cases ok_inj' hsres
              cases ok_inj' hsres
              rename_i h15
              split at hq15
              · cases ok_inj' hq15; exact absurd rfl h15
              rename_i hvneg
              obtain ⟨B4, hB4, hq15⟩ := bind_eq_ok hq15
              rw [hB] at hB4; cases ok_inj' hB4
              obtain ⟨inst4, hinst4, hq15⟩ := bind_eq_ok hq15
              rw [hinst] at hinst4; cases ok_inj' hinst4
              obtain ⟨q14, hq14, hq15⟩ := bind_eq_ok hq15
              obtain ⟨r14, vg6⟩ := q14
              try simp only [uncurry_apply_pair] at hq15
              cases ok_inj' hq15
              obtain ⟨e6, d6, h6⟩ := eval_inst_sound hq14 hdi
                (vidsOK_extends (vg_extends_trans heb (vg_extends_trans e1 hei)) hv)
              dsimp only at e6 d6 h6
              have hvr : v = r14 := i32_ext (by simpa using h15)
              subst hvr
              have hv0 : 0 ≤ v.val := by simpa [i32_lt_iff] using hvneg
              obtain ⟨hvalid, hcase⟩ := h6 hv0
              refine ⟨e6, d6, fun _ => ⟨v, by rw [List.getElem?_eq_getElem hvl, hvv], hvalid, ?_⟩⟩
              rcases hcase with hp | ⟨-, hl⟩
              · exact Or.inl hp
              · exact Or.inr hl
            · rename_i hneg
              cases ok_inj' hsres
              exact ⟨vg_extends_refl _, hdi, fun h => absurd (by simpa [i32_le_iff] using h) hneg⟩
          cases sres with
          | inl e =>
            simp only at hc
            rw [← ok_inj' hc]
            show e.1 = false
            split at hsres
            · obtain ⟨v, -, hsres⟩ := bind_eq_ok hsres
              obtain ⟨q15, -, hsres⟩ := bind_eq_ok hsres
              obtain ⟨t15, vg5⟩ := q15
              try simp only [uncurry_apply_pair] at hsres
              split at hsres
              · cases ok_inj' hsres; rfl
              · cases ok_inj' hsres
            · cases ok_inj' hsres
          | inr vg3 =>
            simp only at hc
            rw [← ok_inj' hc]
            dsimp only
            obtain ⟨e3, d3, h3⟩ := hstep vg3 rfl
            refine ⟨by omega, vg_extends_trans hei e3, d3, fun i hi0 hi hi' hd0 => ?_⟩
            by_cases hii : i = iI
            · subst hii
              rw [hiv] at hd0 ⊢
              exact h3 hd0
            · have hne : i.val ≠ iI.val := fun e => hii (i32_ext e)
              obtain ⟨v, hv1, hvv, hc1⟩ := halli i hi0 hi (by omega) hd0
              refine ⟨v, hv1, extends_valid e3 hvv, ?_⟩
              rcases hc1 with hc1 | hc1
              · exact Or.inl (pureDef_extends e3 hvv hc1)
              · exact Or.inr ⟨hc1.1, by rw [extends_nodeAt e3 hvv]; exact hc1.2⟩
        · rename_i hige
          have hige' : B.insts.val.length ≤ iI.val := by simpa [i32_lt_iff, hni1] using hige
          rw [← ok_inj' hc]
          exact ⟨hei, hdi, fun i hi0 hi hd0 => halli i hi0 hi (by omega) hd0⟩
      cases s2 with
      | inl e =>
        simp only at hc
        rw [← ok_inj' hc]
        exact key2
      | inr y =>
        obtain ⟨i1, vg2⟩ := y
        simp only at hc
        rw [← ok_inj' hc]
        dsimp only
        obtain ⟨e2, d2, hinsts⟩ := key2
        refine ⟨by omega, vg_extends_trans heb (vg_extends_trans e1 e2), d2, fun b hb hbl => ?_⟩
        by_cases hbb : b = bI
        · subst hbb
          intro B' hB'
          rw [hBb] at hB'; cases hB'
          refine ⟨⟨by omega, by omega⟩, fun k P hk hP => ?_, hinsts⟩
          obtain ⟨a, v, hv1, hdef⟩ := hphis k P hk hP
          exact ⟨a, v, hv1, phiDef_extends e2 hdef⟩
        · have hne : b.val ≠ bI.val := fun e => hbb (i32_ext e)
          exact srcDefsBlk_extends (vg_extends_trans e1 e2) (hallb b hb (by omega))
  · rename_i hge
    have hge' : f.blocks.val.length ≤ bI.val := by simpa [i32_lt_iff, hnb] using hge
    rw [← ok_inj' hc]
    exact ⟨heb, hdb, fun b hb hbl => hallb b hb (by omega)⟩

end PionProofs.QbeTvP
