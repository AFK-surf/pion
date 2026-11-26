/-
The checks `replay_pair` and `check_end` make (`tools/qbe_tv/src/validate.pion`), as properties
of the source and target runs: terminator views, matched effects, the pure instructions the
replay skips, the edges between certified pairs.
-/
import PionProofs.QbeTvSim
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Terminator views -/

/-- The atom a terminator reads agrees with `vids`. -/
def TermAgree (G : ValGraph) (env : SymEnv) (vids : List Std.I32) {W : Type} (o : WorldOracle W)
    (regs : Nat → BitVec 64) : Term → Prop
  | .Jnz c _ _ => AtomAgree G env vids o regs c
  | .Ret h _ a => h = true → AtomAgree G env vids o regs a
  | _ => True

theorem termAgree_of_avail {W : Type} {G : ValGraph} {env : SymEnv} {vids : List Std.I32}
    {o : WorldOracle W} {regs : Nat → BitVec 64} {cur : Nat → Prop} (hag : RegsAgree G env cur vids regs)
    (hsym : env.symAddr = o.symAddr) {t : Term} (ha : AvailTerm cur t) : TermAgree G env vids o regs t := by
  cases t with
  | Jnz c _ _ => exact agree_of_avail hag hsym ha
  | Ret h _ a => exact fun hh => agree_of_avail hag hsym (ha hh)
  | _ => trivial

theorem termAgree_down {W : Type} {vg G : ValGraph} (hp : vg_extends vg G) {env : SymEnv}
    {vids : List Std.I32} {o : WorldOracle W} {regs : Nat → BitVec 64} {t : Term}
    (h : TermAgree G env vids o regs t) : TermAgree vg env vids o regs t := by
  cases t with
  | Jnz c _ _ => exact atomAgree_down hp h
  | Ret h' _ a => exact fun hh => atomAgree_down hp (h hh)
  | _ => trivial

/-- What a view of terminator `t` says about the run. -/
def ViewOK (G : ValGraph) {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv)
    (t : Term) : TView → Prop
  | .VJmp s => EdgeTaken o regs t s
  | .VJnz cv s1 s2 => s1 ≠ s2 ∧ ∃ c, t = .Jnz c s1 s2 ∧ (Valid G cv → evI G env cv = atomVal o regs .W c)
  | .VRet h c v => ∃ a, t = .Ret h c a ∧ (h = true → Valid G v → evI G env v = atomVal o regs c a)
  | .VHlt => t = .Hlt

theorem src_view_sound {vg : ValGraph} {f : Func} {vids : Pion.Array Std.I32} {fs : Pion.Array Fact}
    {b : Std.I32} {q : TView × ValGraph} (h : src_view vg f vids fs b = ok q) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ B, f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ b.val ∧
      (∀ cv s1 s2, q.1 = .VJnz cv s1 s2 → Valid q.2 cv ∨ cv.val < 0) ∧
      ∀ G, vg_extends q.2 G → ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
        FactsHold G env fs.val → TermAgree G env vids.val o regs B.term → ViewOK G o regs env B.term q.1 := by
  unfold src_view at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨hb0, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  generalize hT : B.term = T at h
  cases T with
  | Jmp s =>
    simp only at h
    cases ok_inj' h
    exact ⟨vg_extends_refl _, hd, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G _ W o regs env _ _ => by rw [hT]; rfl⟩
  | Jnz c s1 s2 =>
    simp only at h
    split at h
    · rename_i hs
      cases ok_inj' h
      refine ⟨vg_extends_refl _, hd, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G _ W o regs env _ _ => ?_⟩
      rw [hT]; simp only [ViewOK, EdgeTaken, hs, ite_self]
    rename_i hs
    obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
    obtain ⟨cv0, vg1⟩ := q1
    try simp only [uncurry_apply_pair] at h
    obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
    obtain ⟨cv, vg2⟩ := q2
    try simp only [uncurry_apply_pair] at h
    obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hd hv
    obtain ⟨e2, d2, h2v, h2n⟩ := apply_facts_sound hq2 d1
    dsimp only at e1 d1 h1u e2 d2 h2v h2n
    -- the value of the condition, when known
    have hval : ∀ G, vg_extends vg2 G → ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64)
        (env : SymEnv), FactsHold G env fs.val → AtomAgree G env vids.val o regs c → Valid G cv →
        Valid vg2 cv ∧ evI G env cv = atomVal o regs .W c := by
      intro G hG W o regs env hfs hag hvG
      by_cases hvc : Valid vg1 cv0
      · obtain ⟨vcv, ecv⟩ := h2v hvc
        refine ⟨vcv, ?_⟩
        rw [extends_evI hG env vcv, ecv G env hG hfs, atom_use_val hq1 hd hv hvc.1
          (atomAgree_down (vg_extends_trans e1 (vg_extends_trans e2 hG)) hag)]
      · have e := h2n hvc
        simp only [Prod.mk.injEq] at e
        obtain ⟨rfl, rfl⟩ := e
        exfalso
        have hneg : cv.val < 0 := by
          by_contra hc
          exact hvc (h1u (by omega)).1
        exact absurd hvG.1 (by omega)
    obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
    cases t7 with
    | some x =>
      simp only at h
      cases ok_inj' h
      refine ⟨vg_extends_trans e1 e2, d2, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G hG W o regs env hfs hta => ?_⟩
      rw [hT] at hta ⊢
      have hx := vg_const_some ht7
      obtain ⟨-, hcv⟩ := hval G hG o regs env hfs hta (extends_valid hG (constOf_valid hx.1))
      rw [extends_evI hG env (constOf_valid hx.1), constOf_evI d2 env hx.1] at hcv
      simp only [ViewOK, EdgeTaken, ← hcv]
      have hxb : x ≠ 0#u64 ↔ x.bv ≠ 0 := by rw [u64_ne]; exact Iff.rfl
      by_cases hx0 : x ≠ 0#u64
      · rw [ite_eq_left hx0, ite_eq_left (hxb.1 hx0)]
      · rw [ite_eq_right hx0, ite_eq_right (fun h => hx0 (hxb.2 h))]
    | none =>
      simp only at h
      cases ok_inj' h
      refine ⟨vg_extends_trans e1 e2, d2, B, hBb, hb0, fun cv' s1' s2' he => ?_, fun G hG W o regs env hfs hta => ?_⟩
      · simp only [TView.VJnz.injEq] at he
        obtain ⟨rfl, -, -⟩ := he
        by_cases hvc : Valid vg1 cv0
        · exact Or.inl (h2v hvc).1
        · have e := h2n hvc
          simp only [Prod.mk.injEq] at e
          obtain ⟨rfl, rfl⟩ := e
          right
          by_contra hc
          exact hvc (h1u (by omega)).1
      rw [hT] at hta ⊢
      exact ⟨hs, c, rfl, fun hvG => (hval G hG o regs env hfs hta hvG).2⟩
  | Ret hh c a =>
    simp only at h
    split at h
    · rename_i hht
      subst hht
      obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
      obtain ⟨v0, vg3⟩ := q1
      try simp only [uncurry_apply_pair] at h
      obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
      obtain ⟨v, vg4⟩ := q2
      try simp only [uncurry_apply_pair] at h
      cases ok_inj' h
      obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hd hv
      obtain ⟨e2, d2, h2v, h2n⟩ := apply_facts_sound hq2 d1
      dsimp only at e1 d1 h1u e2 d2 h2v h2n
      refine ⟨vg_extends_trans e1 e2, d2, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G hG W o regs env hfs hta => ?_⟩
      rw [hT] at hta ⊢
      refine ⟨a, rfl, fun _ hvG => ?_⟩
      have hag := hta rfl
      by_cases hvc : Valid vg3 v0
      · obtain ⟨vcv, ecv⟩ := h2v hvc
        rw [extends_evI hG env vcv, ecv G env hG hfs, atom_use_val hq1 hd hv hvc.1
          (atomAgree_down (vg_extends_trans e1 (vg_extends_trans e2 hG)) hag)]
      · have e := h2n hvc
        simp only [Prod.mk.injEq] at e
        obtain ⟨rfl, rfl⟩ := e
        exfalso
        have hneg : v.val < 0 := by
          by_contra hc
          exact hvc (h1u (by omega)).1
        exact absurd hvG.1 (by omega)
    · rename_i hhf
      cases ok_inj' h
      refine ⟨vg_extends_refl _, hd, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G hG W o regs env hfs hta => ?_⟩
      rw [hT]
      exact ⟨a, rfl, fun h' => absurd h' hhf⟩
  | Hlt =>
    simp only at h
    cases ok_inj' h
    exact ⟨vg_extends_refl _, hd, B, hBb, hb0, fun _ _ _ h => (by cases h), fun G _ W o regs env _ _ => by rw [hT]; rfl⟩

theorem tgt_view_c_eq : tgt_view_c = src_view := by
  funext vg f vids fs b
  unfold tgt_view_c src_view
  rfl

theorem view_jmp_spec (v : TView) : view_jmp v = ok (match v with | .VJmp s => s | _ => (-1)#i32) := by
  cases v <;> rfl

/-! ## Matched effects -/

theorem extU_maskW (k : Nat) (hk : k ≤ 32) (z : BitVec 64) : maskC .W (extU k (maskC .W z)) = extU k z := by
  apply BitVec.eq_of_toNat_eq
  rw [maskW_toNat, extU_toNat k (by omega), maskW_toNat, extU_toNat k (by omega)]
  have h1 : 2 ^ k ∣ 2 ^ 32 := Nat.pow_dvd_pow 2 hk
  have h2 : z.toNat % 2 ^ k < 2 ^ 32 :=
    lt_of_lt_of_le (Nat.mod_lt _ (Nat.two_pow_pos k)) (Nat.pow_le_pow_right (by norm_num) hk)
  rw [Nat.mod_mod_of_dvd _ h1, Nat.mod_eq_of_lt h2]

theorem maskWidth_eq (w : MemWidth) (v : BitVec 64) : maskWidth w v = match w with
    | .B1 => extU 8 v | .B2 => extU 16 v | .B4 => extU 32 v | .B8 => v := by
  cases w
  · exact and_low 8 v
  · exact and_low 16 v
  · exact and_low 32 v
  · rfl

theorem store_cls_spec (w : MemWidth) : store_cls w = ok (storeCls w) := by cases w <;> rfl

/-- `store_view`: the bits a store of width `w` writes. -/
theorem store_view_sound {vg : ValGraph} {w : MemWidth} {x : Std.I32} {q : Std.I32 × ValGraph}
    (h : store_view vg w x = ok q) (hd : ValGraphDAG vg) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (Valid vg x → Valid q.2 q.1 ∧ ∀ env, evI q.2 env q.1 = maskWidth w (evI vg env x)) ∧
      (¬ Valid vg x → q.1.val < 0) := by
  have hm1 : ¬ Valid vg ((-1)#i32) := fun hc => by have := hc.1; simp at this
  unfold store_view at h
  cases w with
  | B4 =>
    simp only at h
    have h' := pair_ok h
    refine ⟨?_, ?_, fun hvx => ?_, fun hvx => ?_⟩
    · by_cases hvx : Valid vg x
      · exact (vg_use_sound h' hd hvx).1
      · rw [vg_use_invalid h' hvx]; exact vg_extends_refl _
    · by_cases hvx : Valid vg x
      · exact (vg_use_sound h' hd hvx).2.1
      · rw [vg_use_invalid h' hvx]; exact hd
    · obtain ⟨-, -, hv, -, hval⟩ := vg_use_sound h' hd hvx
      refine ⟨hv, fun env => ?_⟩
      rw [hval env, maskWidth_eq]; rfl
    · rw [vg_use_invalid h' hvx]; simp
  | B8 =>
    simp only at h
    have h' := pair_ok h
    refine ⟨?_, ?_, fun hvx => ?_, fun hvx => ?_⟩
    · by_cases hvx : Valid vg x
      · exact (vg_use_sound h' hd hvx).1
      · rw [vg_use_invalid h' hvx]; exact vg_extends_refl _
    · by_cases hvx : Valid vg x
      · exact (vg_use_sound h' hd hvx).2.1
      · rw [vg_use_invalid h' hvx]; exact hd
    · obtain ⟨-, -, hv, -, hval⟩ := vg_use_sound h' hd hvx
      refine ⟨hv, fun env => ?_⟩
      rw [hval env, maskWidth_eq]; rfl
    · rw [vg_use_invalid h' hvx]; simp
  | B1 =>
    simp only at h
    obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
    obtain ⟨y, vg1⟩ := q1
    try simp only [uncurry_apply_pair] at h
    have h' := pair_ok h
    by_cases hvx : Valid vg x
    · obtain ⟨e1, d1, vy, cy, valy⟩ := vg_use_sound hq1 hd hvx
      dsimp only at e1 d1 vy cy valy
      obtain ⟨e2, d2, v2, -, val2⟩ := vg_canon_un_sound vg1 .W .ExtUB d1 y q h' vy
        ⟨fun h => (by cases h), fun _ h => (by rcases h with h | h <;> cases h)⟩
      refine ⟨vg_extends_trans e1 e2, d2, fun _ => ⟨v2, fun env => ?_⟩, fun h => absurd hvx h⟩
      rw [val2 env]
      dsimp only
      rw [valy env, maskWidth_eq]
      exact extU_maskW 8 (by norm_num) _
    · have e := vg_use_invalid hq1 hvx
      simp only [Prod.mk.injEq] at e
      obtain ⟨rfl, rfl⟩ := e
      rw [vg_canon_un_invalid h' hm1]
      exact ⟨vg_extends_refl _, hd, fun h => absurd h hvx, fun _ => by simp⟩
  | B2 =>
    simp only at h
    obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
    obtain ⟨y, vg1⟩ := q1
    try simp only [uncurry_apply_pair] at h
    have h' := pair_ok h
    by_cases hvx : Valid vg x
    · obtain ⟨e1, d1, vy, cy, valy⟩ := vg_use_sound hq1 hd hvx
      dsimp only at e1 d1 vy cy valy
      obtain ⟨e2, d2, v2, -, val2⟩ := vg_canon_un_sound vg1 .W .ExtUH d1 y q h' vy
        ⟨fun h => (by cases h), fun _ h => (by rcases h with h | h <;> cases h)⟩
      refine ⟨vg_extends_trans e1 e2, d2, fun _ => ⟨v2, fun env => ?_⟩, fun h => absurd hvx h⟩
      rw [val2 env]
      dsimp only
      rw [valy env, maskWidth_eq]
      exact extU_maskW 16 (by norm_num) _
    · have e := vg_use_invalid hq1 hvx
      simp only [Prod.mk.injEq] at e
      obtain ⟨rfl, rfl⟩ := e
      rw [vg_canon_un_invalid h' hm1]
      exact ⟨vg_extends_refl _, hd, fun h => absurd h hvx, fun _ => by simp⟩

/-- `obs_eq_c`: under the facts, the source atom and the target atom read the same value. -/
theorem obs_eq_c_sound {vg : ValGraph} {svid tvid : Pion.Array Std.I32} {fs : Pion.Array Fact} {cls : Cls}
    {sa ta : Atom} {q : Bool × ValGraph} (h : obs_eq_c vg svid tvid fs cls sa ta = ok q) (hd : ValGraphDAG vg)
    (hvs : VidsOK vg svid.val) (hvt : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (q.1 = true →
      ∀ G, vg_extends q.2 G → ∀ {W : Type} (o : WorldOracle W) (rs rt : Nat → BitVec 64) (env : SymEnv),
        FactsHold G env fs.val → AtomAgree G env svid.val o rs sa → AtomAgree G env tvid.val o rt ta →
        atomVal o rs cls sa = atomVal o rt cls ta) := by
  unfold obs_eq_c at h
  obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
  obtain ⟨sv, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
  obtain ⟨tv, vg2⟩ := q2
  try simp only [uncurry_apply_pair] at h
  have h3 := pair_ok h
  obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hd hvs
  obtain ⟨e2, d2, h2u⟩ := atom_use_sound hq2 d1 (vidsOK_extends e1 hvt)
  dsimp only at e1 d1 h1u e2 d2 h2u
  obtain ⟨e3, d3⟩ := eq_under_ext h3 d2
  refine ⟨vg_extends_trans e1 (vg_extends_trans e2 e3), d3, fun ht G hG W o rs rt env hfs hsa hta => ?_⟩
  have h3' : eq_under vg2 fs sv tv = ok (true, q.2) := by rw [h3, ← ht]
  obtain ⟨-, -, vsv, vtv, heq⟩ := eq_under_sound h3' d2
  have hsv0 : 0 ≤ sv.val := vsv.1
  have htv0 : 0 ≤ tv.val := vtv.1
  have e123 := vg_extends_trans e1 (vg_extends_trans e2 e3)
  have hs := atom_use_val hq1 hd hvs hsv0 (atomAgree_down (vg_extends_trans e123 hG) hsa)
  have ht' := atom_use_val hq2 d1 (vidsOK_extends e1 hvt) htv0
    (atomAgree_down (vg_extends_trans (vg_extends_trans e2 e3) hG) hta)
  dsimp only at hs ht'
  rw [← hs, ← ht', ← extends_evI e2 env (h1u hsv0).1]
  exact heq G env hG hfs

theorem same_result_true {svid tvid : Pion.Array Std.I32} {sd td : Std.I32}
    (h : same_result svid tvid sd td = ok true) :
    0 ≤ sd.val ∧ 0 ≤ td.val ∧ ∃ v, svid.val[sd.val.toNat]? = some v ∧ 0 ≤ v.val ∧
      tvid.val[td.val.toNat]? = some v := by
  unfold same_result at h
  obtain ⟨t1, ht1, h⟩ := bind_eq_ok h
  obtain ⟨t3, ht3, h⟩ := bind_eq_ok h
  obtain ⟨t5, ht5, h⟩ := bind_eq_ok h
  split at h
  · rename_i h5
    obtain ⟨a, ha, h⟩ := bind_eq_ok h
    obtain ⟨b, hb, h⟩ := bind_eq_ok h
    have hab : a = b := by simpa using ok_inj' h
    subst hab
    obtain ⟨hs0, hsl, hsv⟩ := arr_get_ok hb
    obtain ⟨ht0, htl, htv⟩ := arr_get_ok ha
    split at ht5
    · obtain ⟨c, hc, ht5⟩ := bind_eq_ok ht5
      rw [hb] at hc; cases ok_inj' hc
      have hc0 : 0 ≤ a.val := by
        have := ok_inj' ht5; rw [h5] at this; simpa [i32_le_iff] using this.symm
      exact ⟨hs0, ht0, a, by rw [List.getElem?_eq_getElem hsl, hsv], hc0, by rw [List.getElem?_eq_getElem htl, htv]⟩
    · cases ok_inj' ht5; cases h5
  · cases ok_inj' h

/-- A matched pair of effects: on equal operands and equal worlds the target instruction does
what the source one does, and its result has the source result's symbolic value. -/
def EffMatch (G : ValGraph) (env : SymEnv) (svid tvid : List Std.I32) {W : Type} (o : WorldOracle W)
    (args : List (BitVec 64)) (sinst tinst : Inst) : Prop :=
  ∀ (ss ts ss' : MState W), OpsAgree G env svid o ss.regs sinst → OpsAgree G env tvid o ts.regs tinst →
    ss.world = ts.world → execInst o args ss sinst = some ss' →
    ∃ ts', execInst o args ts tinst = some ts' ∧ ts'.world = ss'.world ∧
      ((instDst tinst).val < 0 ∨ ∃ v, 0 ≤ (instDst sinst).val ∧ 0 ≤ (instDst tinst).val ∧
        svid[(instDst sinst).val.toNat]? = some v ∧ 0 ≤ v.val ∧ tvid[(instDst tinst).val.toNat]? = some v ∧
        ts'.regs (instDst tinst).val.toNat = ss'.regs (instDst sinst).val.toNat)

theorem memWidth_beq {a b : MemWidth} (h : (a == b) = true) : a = b := by
  cases a <;> cases b <;> first | rfl | (exfalso; revert h; decide)

theorem memWidth_bne {a b : MemWidth} (h : (a != b) = false) : a = b := by
  cases a <;> cases b <;> first | rfl | (exfalso; revert h; decide)

theorem memWidth_bne_self (a : MemWidth) : (a != a) = false := by cases a <;> decide

theorem ne_of_bne_false {α : Type} [DecidableEq α] {a b : α} (h : (a != b) = false) : a = b := by
  by_contra hne; simp [hne] at h

theorem match_effect_c_sound {vg : ValGraph} {svid tvid : Pion.Array Std.I32} {fs : Pion.Array Fact}
    {sinst tinst : Inst} {q : Bool × ValGraph} (h : match_effect_c vg svid tvid fs sinst tinst = ok q)
    (ht : q.1 = true) (hd : ValGraphDAG vg) (hvs : VidsOK vg svid.val) (hvt : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∀ G, vg_extends q.2 G → ∀ {W : Type} (o : WorldOracle W)
      (args : List (BitVec 64)) (env : SymEnv), FactsHold G env fs.val →
      EffMatch G env svid.val tvid.val o args sinst tinst := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold match_effect_c at h
  cases sinst with
  | Load sd sc sw ssg sa =>
    cases tinst with
    | Load td tc tw tsg ta =>
      simp only at h
      obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
      obtain ⟨t4, vg1⟩ := q1
      try simp only [uncurry_apply_pair] at h1
      cases t4 with
      | false => simp only [Bool.false_eq_true, ↓reduceIte] at h1; cases ok_inj' h1
      | true =>
        simp only [↓reduceIte] at h1
        obtain ⟨t5, ht5, h2⟩ := bind_eq_ok h1
        have e2 := ok_inj' h2
        simp only [Prod.mk.injEq] at e2
        obtain ⟨et5, eg⟩ := e2
        rw [et5] at ht5
        rw [← eg]
        by_cases hcond : (sc == tc && sw == tw && ssg == tsg) = true
        · rw [ite_eq_left hcond] at hq1
          simp only [Bool.and_eq_true] at hcond
          obtain ⟨⟨ec, ew⟩, eg'⟩ := hcond
          have ec' : sc = tc := by simpa using ec
          have ew' := memWidth_beq ew
          have eg'' : ssg = tsg := by simpa using eg'
          subst ec' ew' eg''
          obtain ⟨e1, d1, hobs⟩ := obs_eq_c_sound (pair_ok hq1) hd hvs hvt
          dsimp only at e1 d1 hobs
          refine ⟨e1, d1, fun G hG W o args env hfs ss ts ss' hos hot hw hex => ?_⟩
          have hval := hobs rfl G hG o ss.regs ts.regs env hfs hos hot
          simp only [execInst] at hex
          cases hl : o.load ss.world sw ssg (atomVal o ss.regs .L sa) with
          | none => rw [hl] at hex; simp at hex
          | some v =>
            rw [hl] at hex; simp only [Option.map_some, Option.some.injEq] at hex
            rw [← hex]
            obtain ⟨hsd0, htd0, w, hsw, hw0, htw⟩ := same_result_true ht5
            refine ⟨{ ts with regs := setReg ts.regs td (maskC sc v) }, ?_, hw.symm,
              Or.inr ⟨w, hsd0, htd0, hsw, hw0, htw, by simp [setReg, instDst]⟩⟩
            simp only [execInst, ← hval, ← hw, hl, Option.map_some]
        · rw [ite_eq_right hcond] at hq1; cases ok_inj' hq1
    | _ => simp only at h; cases ok_inj' h
  | Store sw sv sa =>
    cases tinst with
    | Store tw tv ta =>
      simp only at h
      obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
      obtain ⟨t10, vg3⟩ := q1
      try simp only [uncurry_apply_pair] at h1
      cases t10 with
      | true => simp only [↓reduceIte] at h1; cases ok_inj' h1
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h1
      cases hsw' : (sw != tw) with
      | true => rw [ite_eq_left hsw'] at hq1; cases ok_inj' hq1
      | false =>
      have hsw := memWidth_bne hsw'
      subst hsw
      rw [ite_eq_right (by rw [memWidth_bne_self]; simp)] at hq1
      obtain ⟨q9, hq9, hq1'⟩ := bind_eq_ok hq1
      obtain ⟨t9, vg4⟩ := q9
      try simp only [uncurry_apply_pair] at hq1'
      have e9 := ok_inj' hq1'
      simp only [Prod.mk.injEq] at e9
      obtain ⟨et9, eg9⟩ := e9
      have ht9 : t9 = true := by revert et9; cases t9 <;> simp
      rw [ht9, eg9] at hq9
      obtain ⟨e3, d3, hobs⟩ := obs_eq_c_sound hq9 hd hvs hvt
      dsimp only at e3 d3 hobs
      simp only [store_cls_spec, bind_ok] at h1
      obtain ⟨q5, hq5, h5⟩ := bind_eq_ok h1
      obtain ⟨sv0, vg5⟩ := q5
      try simp only [uncurry_apply_pair] at h5
      obtain ⟨q6, hq6, h6⟩ := bind_eq_ok h5
      obtain ⟨s1, vg6⟩ := q6
      try simp only [uncurry_apply_pair] at h6
      obtain ⟨q7, hq7, h7⟩ := bind_eq_ok h6
      obtain ⟨tv0, vg7⟩ := q7
      try simp only [uncurry_apply_pair] at h7
      obtain ⟨q8, hq8, h8⟩ := bind_eq_ok h7
      obtain ⟨t1, vg8⟩ := q8
      try simp only [uncurry_apply_pair] at h8
      have h9 := pair_ok h8
      have hv3s := vidsOK_extends e3 hvs
      obtain ⟨e5, d5, h5u⟩ := atom_use_sound hq5 d3 hv3s
      obtain ⟨e6, d6, h6v, h6n⟩ := store_view_sound hq6 d5
      have hv6t := vidsOK_extends (vg_extends_trans e3 (vg_extends_trans e5 e6)) hvt
      obtain ⟨e7, d7, h7u⟩ := atom_use_sound hq7 d6 hv6t
      obtain ⟨e8, d8, h8v, h8n⟩ := store_view_sound hq8 d7
      dsimp only at e5 d5 h5u e6 d6 h6v h6n e7 d7 h7u e8 d8 h8v h8n
      obtain ⟨e9, d9⟩ := eq_under_ext h9 d8
      obtain ⟨-, -, vs1, vt1, heq⟩ := eq_under_sound h9 d8
      dsimp only at e9 d9
      have E := vg_extends_trans e3 (vg_extends_trans e5 (vg_extends_trans e6 (vg_extends_trans e7
        (vg_extends_trans e8 e9))))
      refine ⟨E, d9, fun G hG W o args env hfs ss ts ss' hos hot hw hex => ?_⟩
      have hsv0 : Valid vg5 sv0 := by
        by_contra hc
        have := h6n hc
        have := vs1.1
        omega
      have htv0 : Valid vg7 tv0 := by
        by_contra hc
        have := h8n hc
        have := vt1.1
        omega
      obtain ⟨vs1', es1⟩ := h6v hsv0
      obtain ⟨vt1', et1⟩ := h8v htv0
      have hs := atom_use_val hq5 d3 hv3s hsv0.1
        (atomAgree_down (vg_extends_trans (vg_extends_trans e5 (vg_extends_trans e6 (vg_extends_trans e7
          (vg_extends_trans e8 e9)))) hG) hos.1)
      have ht' := atom_use_val hq7 d6 hv6t htv0.1
        (atomAgree_down (vg_extends_trans (vg_extends_trans e7 (vg_extends_trans e8 e9)) hG) hot.1)
      dsimp only at hs ht'
      have hveq : maskWidth sw (atomVal o ss.regs (storeCls sw) sv) =
          maskWidth sw (atomVal o ts.regs (storeCls sw) tv) := by
        have := heq G env hG hfs
        rw [extends_evI (vg_extends_trans e7 e8) env vs1', es1 env, et1 env, hs, ht'] at this
        exact this
      have haeq := hobs rfl G (vg_extends_trans (vg_extends_trans e5 (vg_extends_trans e6 (vg_extends_trans e7
        (vg_extends_trans e8 e9)))) hG) o ss.regs ts.regs env hfs hos.2 hot.2
      simp only [execInst] at hex
      cases hst : o.store ss.world sw (maskWidth sw (atomVal o ss.regs (storeCls sw) sv))
          (atomVal o ss.regs .L sa) with
      | none => rw [hst] at hex; simp at hex
      | some w' =>
        rw [hst] at hex; simp only [Option.map_some, Option.some.injEq] at hex
        rw [← hex]
        refine ⟨{ ts with world := w' }, ?_, rfl, Or.inl (by simp [instDst])⟩
        simp only [execInst, ← hveq, ← haeq, ← hw, hst, Option.map_some]
    | _ => simp only at h; cases ok_inj' h
  | Call sd sc sh scal sargs =>
    cases tinst with
    | Call td tc th tcal targs =>
      simp only at h
      obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
      obtain ⟨t25, vg10⟩ := q1
      try simp only [uncurry_apply_pair] at h1
      cases t25 with
      | true => simp only [↓reduceIte] at h1; cases ok_inj' h1
      | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h1
      cases hcond : ((sh != th) || (sh && (sc != tc))) with
      | true => rw [ite_eq_left hcond] at hq1; cases ok_inj' hq1
      | false =>
      rw [ite_eq_right (by simp [hcond])] at hq1
      have hshth : sh = th := by revert hcond; cases sh <;> cases th <;> simp
      subst hshth
      have hcls : sh = true → sc = tc := by
        intro hsh; subst hsh; revert hcond; by_cases e : sc = tc <;> simp [e]
      obtain ⟨q9, hq9, hq1'⟩ := bind_eq_ok hq1
      obtain ⟨t9, vg4⟩ := q9
      try simp only [uncurry_apply_pair] at hq1'
      have e9 := ok_inj' hq1'
      simp only [Prod.mk.injEq] at e9
      obtain ⟨et9, eg9⟩ := e9
      have ht9 : t9 = true := by revert et9; cases t9 <;> simp
      rw [ht9, eg9] at hq9
      obtain ⟨e10, d10, hobsc⟩ := obs_eq_c_sound hq9 hd hvs hvt
      dsimp only at e10 d10 hobsc
      obtain ⟨n, hn, h2⟩ := bind_eq_ok h1
      obtain ⟨hn1, hn2⟩ := arr_length_ok hn
      obtain ⟨n2, hn2', h3⟩ := bind_eq_ok h2
      obtain ⟨hn21, -⟩ := arr_length_ok hn2'
      by_cases hnn : n = n2
      · rw [ite_eq_right (by simp [hnn])] at h3
        have hlen : sargs.val.length = targs.val.length := by subst hnn; omega
        obtain ⟨s, hs, h4⟩ := bind_eq_ok h3
        unfold match_effect_c_loop0 at hs
        have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
            match x with | (j, vg) => match_effect_c_loop0.body n sargs targs svid tvid fs j vg)
          (fun x => 0 ≤ x.1.val ∧ vg_extends vg10 x.2 ∧ ValGraphDAG x.2 ∧
            ∀ k (hk : k < sargs.val.length) (hk' : k < targs.val.length), k < x.1.val.toNat →
              sargs.val[k].cls = targs.val[k].cls ∧
              ∀ G, vg_extends x.2 G → ∀ {W : Type} (o : WorldOracle W) (rs rt : Nat → BitVec 64) (env : SymEnv),
                FactsHold G env fs.val → AtomAgree G env svid.val o rs sargs.val[k].arg →
                AtomAgree G env tvid.val o rt targs.val[k].arg →
                atomVal o rs sargs.val[k].cls sargs.val[k].arg = atomVal o rt targs.val[k].cls targs.val[k].arg)
          (fun r => match r with
            | .inl e => e.1 = false
            | .inr y => vg_extends vg10 y.2 ∧ ValGraphDAG y.2 ∧
              ∀ k (hk : k < sargs.val.length) (hk' : k < targs.val.length),
              sargs.val[k].cls = targs.val[k].cls ∧
              ∀ G, vg_extends y.2 G → ∀ {W : Type} (o : WorldOracle W) (rs rt : Nat → BitVec 64) (env : SymEnv),
                FactsHold G env fs.val → AtomAgree G env svid.val o rs sargs.val[k].arg →
                AtomAgree G env tvid.val o rt targs.val[k].arg →
                atomVal o rs sargs.val[k].cls sargs.val[k].arg = atomVal o rt targs.val[k].cls targs.val[k].arg)
          ?_ _ _ hs ⟨by simp, vg_extends_refl _, d10, fun k _ _ hk => by simp at hk⟩
        · cases s with
          | inl e =>
            simp only at h4
            have e4 := ok_inj' h4
            simp only at key
            rw [e4] at key; cases key
          | inr y =>
            obtain ⟨j1, vg12⟩ := y
            obtain ⟨e12, d12, hargs⟩ := key
            simp only at h4
            have hres : qg = vg12 ∧ (sh = true → same_result svid tvid sd td = ok true) := by
              cases hsh : sh
              · rw [hsh] at h4; simp only [Bool.not_false, ↓reduceIte] at h4
                have e4 := ok_inj' h4; simp only [Prod.mk.injEq] at e4
                exact ⟨e4.2.symm, fun h' => by cases h'⟩
              · rw [hsh] at h4; simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h4
                obtain ⟨t36, ht36, h5⟩ := bind_eq_ok h4
                have e5 := ok_inj' h5; simp only [Prod.mk.injEq] at e5
                exact ⟨e5.2.symm, fun _ => by rw [ht36, e5.1]⟩
            obtain ⟨hq2, hsr⟩ := hres
            rw [hq2]
            refine ⟨vg_extends_trans e10 e12, d12, fun G hG W o args env hfs ss ts ss' hos hot hw hex => ?_⟩
            have hcal := hobsc rfl G (vg_extends_trans e12 hG) o ss.regs ts.regs env hfs hos.1 hot.1
            have hal : (sargs.val.map fun ca => (ca.cls, atomVal o ss.regs ca.cls ca.arg)) =
                (targs.val.map fun ca => (ca.cls, atomVal o ts.regs ca.cls ca.arg)) := by
              apply List.ext_getElem (by simp [hlen])
              intro k hk1 hk2
              simp only [List.getElem_map]
              have hk1' : k < sargs.val.length := by simpa using hk1
              have hk2' : k < targs.val.length := by simpa using hk2
              obtain ⟨hc, hv⟩ := hargs k hk1' hk2'
              rw [hv G hG o ss.regs ts.regs env hfs (hos.2 _ (List.getElem_mem _))
                (hot.2 _ (List.getElem_mem _)), hc]
            simp only [execInst] at hex
            cases hcall : o.call ss.world (atomVal o ss.regs .L scal)
                (sargs.val.map fun ca => (ca.cls, atomVal o ss.regs ca.cls ca.arg)) with
            | none => rw [hcall] at hex; simp at hex
            | some p =>
              rw [hcall] at hex; simp only [Option.map_some, Option.some.injEq] at hex
              rw [← hex]
              refine ⟨{ regs := if sh then setReg ts.regs td (maskC tc p.2) else ts.regs, world := p.1 },
                ?_, rfl, ?_⟩
              · simp only [execInst, ← hcal, ← hal, ← hw, hcall, Option.map_some]
              · cases hshv : sh
                · left; simp [instDst]
                · obtain ⟨hsd0, htd0, w, hsw, hw0, htw⟩ := same_result_true (hsr hshv)
                  refine Or.inr ⟨w, by simpa [instDst] using hsd0, by simpa [instDst] using htd0,
                    by simpa [instDst] using hsw, hw0, by simpa [instDst] using htw, ?_⟩
                  simp [instDst, setReg, hcls hshv]
        rintro ⟨jI, vgj⟩ c ⟨hj0, hej, hdj, hall⟩ hc
        try dsimp only at hj0 hej hdj hall hc
        unfold match_effect_c_loop0.body at hc
        by_cases hlt : jI < n
        · rw [ite_eq_left hlt] at hc
          have hlt' : jI.val < sargs.val.length := by simpa [i32_lt_iff, hn1] using hlt
          have hjs := i32_succ_val' hlt' hn2
          obtain ⟨SA, hSA, hc1⟩ := bind_eq_ok hc
          obtain ⟨_, hSAl, hSAv⟩ := arr_get_ok hSA
          obtain ⟨TA, hTA, hc2⟩ := bind_eq_ok hc1
          obtain ⟨_, hTAl, hTAv⟩ := arr_get_ok hTA
          obtain ⟨q39, hq39, hc3⟩ := bind_eq_ok hc2
          obtain ⟨t39, vg1⟩ := q39
          try simp only [uncurry_apply_pair] at hc3
          cases t39 with
          | true => simp only [↓reduceIte] at hc3; rw [← ok_inj' hc3]
          | false =>
          simp only [Bool.false_eq_true, ↓reduceIte] at hc3
          have hcl : SA.cls = TA.cls := by
            by_contra hne
            rw [ite_eq_left (by simp [hne])] at hq39
            cases ok_inj' hq39
          rw [ite_eq_right (by simp [hcl])] at hq39
          obtain ⟨SA2, hSA2, hq39⟩ := bind_eq_ok hq39
          rw [hSA] at hSA2; cases ok_inj' hSA2
          obtain ⟨SA3, hSA3, hq39⟩ := bind_eq_ok hq39
          rw [hSA] at hSA3; cases ok_inj' hSA3
          obtain ⟨TA2, hTA2, hq39⟩ := bind_eq_ok hq39
          rw [hTA] at hTA2; cases ok_inj' hTA2
          obtain ⟨q38, hq38, hq39'⟩ := bind_eq_ok hq39
          obtain ⟨t38, vg2⟩ := q38
          try simp only [uncurry_apply_pair] at hq39'
          have e := ok_inj' (show ok ((!t38), vg2) = ok (false, vg1) from hq39')
          simp only [Prod.mk.injEq] at e
          obtain ⟨e1, eg⟩ := e
          have ht38 : t38 = true := by revert e1; cases t38 <;> simp
          rw [ht38, eg] at hq38
          obtain ⟨e2, d2, hobs2⟩ := obs_eq_c_sound hq38 hdj (vidsOK_extends (vg_extends_trans e10 hej) hvs)
            (vidsOK_extends (vg_extends_trans e10 hej) hvt)
          dsimp only at e2 d2 hobs2
          rw [← ok_inj' hc3]
          dsimp only
          refine ⟨by omega, vg_extends_trans hej e2, d2, fun k hk hk' hkl => ?_⟩
          by_cases hkj : k = jI.val.toNat
          · subst hkj
            rw [hSAv, hTAv]
            refine ⟨hcl, fun G hG W o rs rt env hfs ha1 ha2 => ?_⟩
            rw [← hcl]
            exact hobs2 rfl G hG o rs rt env hfs ha1 ha2
          · obtain ⟨hc1, hv1⟩ := hall k hk hk' (by omega)
            exact ⟨hc1, fun G hG => hv1 G (vg_extends_trans e2 hG)⟩
        · rw [ite_eq_right hlt] at hc
          have hge' : sargs.val.length ≤ jI.val := by simpa [i32_lt_iff, hn1] using hlt
          rw [← ok_inj' hc]
          exact ⟨hej, hdj, fun k hk hk' => hall k hk hk' (by omega)⟩
      · rw [ite_eq_left hnn] at h3; cases ok_inj' h3
    | _ => simp only at h; cases ok_inj' h
  | Alloc sd sal ssz =>
    cases tinst with
    | Alloc td tal tsz =>
      simp only at h
      by_cases hc : (sal == tal && ssz == tsz) = true
      · rw [ite_eq_left hc] at h
        obtain ⟨t39, ht39, h1⟩ := bind_eq_ok h
        have e1 := ok_inj' h1
        simp only [Prod.mk.injEq] at e1
        rw [e1.1] at ht39
        rw [← e1.2]
        simp only [Bool.and_eq_true, beq_iff_eq] at hc
        rw [← hc.1, ← hc.2]
        refine ⟨vg_extends_refl _, hd, fun G hG W o args env hfs ss ts ss' hos hot hw hex => ?_⟩
        simp only [execInst] at hex
        cases ha : o.alloc ss.world sal ssz with
        | none => rw [ha] at hex; simp at hex
        | some p =>
          rw [ha] at hex; simp only [Option.map_some, Option.some.injEq] at hex
          rw [← hex]
          obtain ⟨hsd0, htd0, w, hsw, hw0, htw⟩ := same_result_true ht39
          refine ⟨{ regs := setReg ts.regs td p.2, world := p.1 }, ?_, rfl,
            Or.inr ⟨w, hsd0, htd0, hsw, hw0, htw, by simp [setReg, instDst]⟩⟩
          simp only [execInst, ← hw, ha, Option.map_some]
      · rw [ite_eq_right hc] at h; cases ok_inj' h
    | _ => simp only at h; cases ok_inj' h
  | Bin sd sc sop sa sb =>
    cases tinst with
    | Bin td tc top ta tb =>
      simp only [binop_arg_cls_spec0, binop_arg_cls_spec1, bind_ok] at h
      obtain ⟨q45, hq45, h1⟩ := bind_eq_ok h
      obtain ⟨t45, vg13⟩ := q45
      try simp only [uncurry_apply_pair] at h1
      obtain ⟨q49, hq49, h2⟩ := bind_eq_ok h1
      obtain ⟨t49, vg15⟩ := q49
      try simp only [uncurry_apply_pair] at h2
      cases t49 with
      | false => simp only [Bool.false_eq_true, ↓reduceIte] at h2; cases ok_inj' h2
      | true =>
      simp only [↓reduceIte] at h2
      obtain ⟨t50, ht50, h3⟩ := bind_eq_ok h2
      have e3 := ok_inj' h3
      simp only [Prod.mk.injEq] at e3
      rw [e3.1] at ht50
      rw [← e3.2]
      cases t45 with
      | false => simp only [Bool.false_eq_true, ↓reduceIte] at hq49; cases ok_inj' hq49
      | true =>
      simp only [↓reduceIte] at hq49
      by_cases hc : (sc == tc && sop == top) = true
      · rw [ite_eq_left hc] at hq45
        simp only [Bool.and_eq_true, beq_iff_eq] at hc
        obtain ⟨ec, eo⟩ := hc
        subst ec eo
        obtain ⟨e13, d13, hobs0⟩ := obs_eq_c_sound (pair_ok hq45) hd hvs hvt
        dsimp only at e13 d13 hobs0
        obtain ⟨e15, d15, hobs1⟩ := obs_eq_c_sound (pair_ok hq49) d13 (vidsOK_extends e13 hvs)
          (vidsOK_extends e13 hvt)
        dsimp only at e15 d15 hobs1
        refine ⟨vg_extends_trans e13 e15, d15, fun G hG W o args env hfs ss ts ss' hos hot hw hex => ?_⟩
        have h0 := hobs0 rfl G (vg_extends_trans e15 hG) o ss.regs ts.regs env hfs hos.1 hot.1
        have h1' := hobs1 rfl G hG o ss.regs ts.regs env hfs hos.2 hot.2
        simp only [execInst] at hex
        cases hb : evalBin sc sop (atomVal o ss.regs (binArgCls sop sc 0) sa)
            (atomVal o ss.regs (binArgCls sop sc 1) sb) with
        | none => rw [hb] at hex; simp at hex
        | some v =>
          rw [hb] at hex; simp only [Option.map_some, Option.some.injEq] at hex
          rw [← hex]
          obtain ⟨hsd0, htd0, w, hsw, hw0, htw⟩ := same_result_true ht50
          refine ⟨{ ts with regs := setReg ts.regs td v }, ?_, hw.symm,
            Or.inr ⟨w, hsd0, htd0, hsw, hw0, htw, by simp [setReg, instDst]⟩⟩
          simp only [execInst, ← h0, ← h1', hb, Option.map_some]
      · rw [ite_eq_right hc] at hq45; cases ok_inj' hq45
    | _ => simp only at h; cases ok_inj' h
  | Par _ _ _ => simp only at h; cases ok_inj' h
  | Un _ _ _ _ => simp only at h; cases ok_inj' h

/-! ## The instructions the replay skips -/

/-- Instructions that leave the world alone. -/
def NoWorld : Inst → Prop
  | .Par _ _ _ => True
  | .Un _ _ _ _ => True
  | .Bin _ _ _ _ _ => True
  | _ => False

theorem execInst_world {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {s s' : MState W}
    {inst : Inst} (hn : NoWorld inst) (h : execInst o args s inst = some s') : s'.world = s.world := by
  cases inst with
  | Par d c k => simp only [execInst, Option.some.injEq] at h; subst h; rfl
  | Un d c op a => simp only [execInst, Option.some.injEq] at h; subst h; rfl
  | Bin d c op a b =>
    simp only [execInst] at h
    cases hx : evalBin c op (atomVal o s.regs (binArgCls op c 0) a) (atomVal o s.regs (binArgCls op c 1) b) with
    | none => rw [hx] at h; simp at h
    | some v => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; rfl
  | _ => exact absurd hn (by simp [NoWorld])

theorem execInst_load_world {W : Type} {o : WorldOracle W} {args : List (BitVec 64)} {s s' : MState W}
    {d : Std.I32} {c : Cls} {w : MemWidth} {sg : Bool} {a : Atom}
    (h : execInst o args s (.Load d c w sg a) = some s') : s'.world = s.world := by
  simp only [execInst] at h
  cases hx : o.load s.world w sg (atomVal o s.regs .L a) with
  | none => rw [hx] at h; simp at h
  | some v => rw [hx] at h; simp only [Option.map_some, Option.some.injEq] at h; subst h; rfl

theorem src_inst_is_effect_false {vg : ValGraph} {svid : Pion.Array Std.I32} {inst : Inst} {b i : Std.I32}
    (h : src_inst_is_effect vg svid inst b i = ok false) : NoWorld inst := by
  cases inst with
  | Par _ _ _ => trivial
  | Un _ _ _ _ => trivial
  | Bin _ _ _ _ _ => trivial
  | _ => simp [src_inst_is_effect] at h

theorem src_inst_is_effect_bin {vg : ValGraph} {svid : Pion.Array Std.I32} {d : Std.I32} {c : Cls}
    {op : BinOp} {a x : Atom} {b i : Std.I32} (h : src_inst_is_effect vg svid (.Bin d c op a x) b i = ok true) :
    trapOp op = true ∧ (d.val < 0 ∨ svid.val.length ≤ d.val.toNat ∨
      (∀ v, svid.val[d.val.toNat]? = some v → ¬ Valid vg v) ∨
      ∃ v, svid.val[d.val.toNat]? = some v ∧ nodeAt vg v = some (.SEffect c b i)) := by
  unfold src_inst_is_effect at h
  simp only [is_trapping_binop_spec, bind_ok] at h
  cases htr : trapOp op
  · rw [htr] at h; simp at h
  rw [htr] at h
  simp only [↓reduceIte] at h
  refine ⟨rfl, ?_⟩
  obtain ⟨t3, ht3, h⟩ := bind_eq_ok h
  obtain ⟨t6, ht6, h⟩ := bind_eq_ok h
  by_cases hd0 : d.val < 0
  · exact Or.inl hd0
  have ht3f : t3 = decide (svid.val.length ≤ d.val.toNat) := by
    rw [ite_eq_right (by simpa [i32_lt_iff] using hd0)] at ht3
    obtain ⟨n, hn, ht3⟩ := bind_eq_ok ht3
    obtain ⟨hn1, -⟩ := arr_length_ok hn
    rw [← ok_inj' ht3]
    simp only [decide_eq_decide, ge_iff_le, i32_le_iff, hn1]
    omega
  subst ht3f
  by_cases hl : svid.val.length ≤ d.val.toNat
  · exact Or.inr (Or.inl hl)
  simp only [hl, decide_false, Bool.false_eq_true, ↓reduceIte] at ht6
  obtain ⟨v, hv, ht6⟩ := bind_eq_ok ht6
  obtain ⟨_, hvl, hvv⟩ := arr_get_ok hv
  have hsv : svid.val[d.val.toNat]? = some v := by rw [List.getElem?_eq_getElem hvl, hvv]
  obtain ⟨t5, ht5, ht6⟩ := bind_eq_ok ht6
  obtain ⟨ht51, -⟩ := vg_valid_ok ht5
  cases t5 with
  | false =>
    right; right; left
    intro w hw hvw
    rw [hsv] at hw; cases hw
    exact absurd (ht51.2 hvw) (by simp)
  | true =>
    cases ok_inj' ht6
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
    obtain ⟨v2, hv2, h⟩ := bind_eq_ok h
    rw [hv] at hv2; cases ok_inj' hv2
    obtain ⟨node, hnode, h⟩ := bind_eq_ok h
    obtain ⟨_, hnl, hnv⟩ := arr_get_ok hnode
    have hvalid := ht51.1 rfl
    right; right; right
    refine ⟨v, hsv, ?_⟩
    rw [(sym_node_eq_ok (bind_id_ok h)).1 rfl] at hnv
    simp only [nodeAt, hvalid.1, ↓reduceIte]
    rw [List.getElem?_eq_getElem hnl, hnv]

theorem skip_src_pure_sound {vg : ValGraph} {f : Func} {svid : Pion.Array Std.I32} {b x0 x1 : Std.I32}
    (h : skip_src_pure vg f svid b x0 = ok x1) (hx0 : 0 ≤ x0.val) :
    ∃ B, f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ b.val ∧ x0.val ≤ x1.val ∧
      (x0.val ≤ B.insts.val.length → x1.val ≤ B.insts.val.length) ∧
      (∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < x1.val.toNat → NoWorld B.insts.val[i]) ∧
      (∀ hx : x1.val.toNat < B.insts.val.length, 0 ≤ x1.val →
        src_inst_is_effect vg svid B.insts.val[x1.val.toNat] b x1 = ok true) := by
  unfold skip_src_pure at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨hb0, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨x2, hx2, h⟩ := bind_eq_ok h
  cases ok_inj' h
  unfold skip_src_pure_loop0 at hx2
  have key := loop_ok_inv (fun x => skip_src_pure_loop0.body n f b vg svid x)
    (fun x => x0.val ≤ x.val ∧ (x0.val ≤ B.insts.val.length → x.val ≤ B.insts.val.length) ∧
      ∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < x.val.toNat → NoWorld B.insts.val[i])
    (fun y => x0.val ≤ y.val ∧ (x0.val ≤ B.insts.val.length → y.val ≤ B.insts.val.length) ∧
      (∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < y.val.toNat → NoWorld B.insts.val[i]) ∧
      (∀ hx : y.val.toNat < B.insts.val.length, 0 ≤ y.val →
        src_inst_is_effect vg svid B.insts.val[y.val.toNat] b y = ok true))
    ?_ _ _ hx2 ⟨le_refl _, fun h => h, fun i _ h1 h2 => by omega⟩
  · exact ⟨B, hBb, hb0, key⟩
  intro x c ⟨hx1, hxl, hall⟩ hc
  unfold skip_src_pure_loop0.body at hc
  obtain ⟨t5, ht5, hc⟩ := bind_eq_ok hc
  by_cases hlt : x < n
  · rw [ite_eq_left hlt] at ht5
    have hlt' : x.val < B.insts.val.length := by simpa [i32_lt_iff, hn1] using hlt
    obtain ⟨B2, hB2, ht5⟩ := bind_eq_ok ht5
    rw [hB] at hB2; cases ok_inj' hB2
    obtain ⟨inst, hinst, ht5⟩ := bind_eq_ok ht5
    obtain ⟨hxx0, hil, hiv⟩ := arr_get_ok hinst
    obtain ⟨e, he, ht5⟩ := bind_eq_ok ht5
    cases ok_inj' ht5
    cases e with
    | false =>
      simp only [Bool.not_false, ↓reduceIte] at hc
      rw [← ok_inj' hc]
      have hxs := i32_succ_val' hlt' hn2
      refine ⟨by omega, fun _ => by omega, fun i hi h1 h2 => ?_⟩
      by_cases hix : i = x.val.toNat
      · subst hix; rw [hiv]; exact src_inst_is_effect_false he
      · exact hall i hi h1 (by omega)
    | true =>
      simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at hc
      rw [← ok_inj' hc]
      exact ⟨hx1, hxl, hall, fun _ _ => by rw [hiv]; exact he⟩
  · rw [ite_eq_right hlt] at ht5
    cases ok_inj' ht5
    simp only [Bool.false_eq_true, ↓reduceIte] at hc
    rw [← ok_inj' hc]
    have hge : B.insts.val.length ≤ x.val := by simpa [i32_lt_iff, hn1] using hlt
    exact ⟨hx1, hxl, hall, fun hx _ => absurd hx (by omega)⟩

/-- `bin_safe`: the division cannot trap, whatever the left operand when it is not a known
constant. -/
theorem bin_safe_any {vg : ValGraph} {c : Cls} {op : BinOp} {av bv : Std.I32}
    (h : bin_safe vg c op av bv = ok true) (hd : ValGraphDAG vg) (env : SymEnv) (x : BitVec 64)
    (hx : Valid vg av → x = evI vg env av) :
    Valid vg bv ∧ evalBin c op x (evI vg env bv) ≠ none := by
  unfold bin_safe at h
  obtain ⟨ob, hob, h⟩ := bind_eq_ok h
  cases ob with
  | none => simp at h
  | some y =>
    try simp only at h
    obtain ⟨hy, -⟩ := vg_const_some hob
    have hbv := constOf_evI hd env hy
    refine ⟨constOf_valid hy, ?_⟩
    obtain ⟨oa, hoa, h⟩ := bind_eq_ok h
    obtain ⟨r, hr, h⟩ := bind_eq_ok h
    have hrt : r = true := ok_inj' h
    subst hrt
    rw [hbv]
    have hsafe : ∀ a : BitVec 64, (∀ l, oa = some l → a = l.bv) → safeDiv c op a y.bv := by
      intro a ha
      cases oa with
      | some l =>
        rw [is_safe_div_const_spec] at hr
        have := ok_inj' hr
        simp only [decide_eq_true_eq] at this
        rw [ha l rfl]; exact this
      | none =>
        unfold is_safe_div_const at hr
        simp only [mask_cls_spec, is_signed_div_spec, all_ones_spec, bind_ok] at hr
        split at hr
        · simp at hr
        · rename_i h0
          have h0' : maskC c y.bv ≠ 0 := fun e => h0 (u64_ext (by simp [e]))
          refine ⟨h0', fun hs hall => ?_⟩
          simp only [hs, ↓reduceIte, bind_ok] at hr
          have hbeq : ((⟨maskC c y.bv⟩ : Std.U64) == ⟨allOnesC c⟩) = true := by simp [hall]
          rw [hbeq] at hr
          simp at hr
    have hs := hsafe x (fun l hl => by
      have hc := vg_const_none_or hoa l hl
      rw [hx (constOf_valid hc)]
      exact constOf_evI hd env hc)
    have hsm : safeDiv c op (maskC c x) (maskC c y.bv) := by
      unfold safeDiv at hs ⊢
      simp only [maskC_idem]
      exact hs
    cases op <;> simp [evalBin, hsm, ite_some_some_ne_none]

/-- A target instruction the replay may run without a source counterpart: no effect on the
world, and no trap (a division only when its divisor is a safe constant, its value checked). -/
def PureTgt (G : ValGraph) (tvid : List Std.I32) (inst : Inst) : Prop :=
  NoWorld inst ∧ (TgtChecked inst ∨ ∃ d c op a bb, inst = .Bin d c op a bb ∧ trapOp op = true ∧
    (∀ {W : Type} (o : WorldOracle W) (env : SymEnv) (regs : Nat → BitVec 64),
      AtomAgree G env tvid o regs a → AtomAgree G env tvid o regs bb →
      evalBin c op (atomVal o regs (binArgCls op c 0) a) (atomVal o regs (binArgCls op c 1) bb) ≠ none) ∧
    (∀ v, 0 ≤ d.val → tvid[d.val.toNat]? = some v → 0 ≤ v.val → Valid G v ∧ PureDef G tvid inst v))

theorem pureTgt_extends {G G' : ValGraph} (hp : vg_extends G G') {tvid : List Std.I32} {inst : Inst}
    (h : PureTgt G tvid inst) : PureTgt G' tvid inst := by
  obtain ⟨hn, hc | ⟨d, c, op, a, bb, rfl, htr, hsafe, hval⟩⟩ := h
  · exact ⟨hn, Or.inl hc⟩
  · refine ⟨hn, Or.inr ⟨d, c, op, a, bb, rfl, htr, fun o env regs ha hb =>
      hsafe o env regs (atomAgree_down hp ha) (atomAgree_down hp hb), fun v h0 hv hv0 => ?_⟩⟩
    obtain ⟨vv, pd⟩ := hval v h0 hv hv0
    exact ⟨extends_valid hp vv, pureDef_extends hp vv pd⟩

theorem tgt_effect_c_false_sound {vg : ValGraph} {tvid : Pion.Array Std.I32} {inst : Inst} {vg1 : ValGraph}
    (h : tgt_effect_c vg tvid inst = ok (false, vg1)) (hd : ValGraphDAG vg) (hv : VidsOK vg tvid.val) :
    vg_extends vg vg1 ∧ ValGraphDAG vg1 ∧ NoWorld inst ∧ (TgtChecked inst ∨
      ∃ d c op a bb, inst = .Bin d c op a bb ∧ trapOp op = true ∧
      ∀ G, vg_extends vg1 G → ∀ {W : Type} (o : WorldOracle W) (env : SymEnv) (regs : Nat → BitVec 64),
        AtomAgree G env tvid.val o regs a → AtomAgree G env tvid.val o regs bb →
        evalBin c op (atomVal o regs (binArgCls op c 0) a) (atomVal o regs (binArgCls op c 1) bb) ≠ none) := by
  unfold tgt_effect_c at h
  cases inst with
  | Par d c k => cases ok_inj' h; exact ⟨vg_extends_refl _, hd, trivial, Or.inl trivial⟩
  | Un d c op a => cases ok_inj' h; exact ⟨vg_extends_refl _, hd, trivial, Or.inl trivial⟩
  | Bin d c op a bb =>
    simp only [is_trapping_binop_spec, bind_ok] at h
    cases htr : trapOp op
    · rw [htr] at h; simp only [Bool.not_false, ↓reduceIte] at h; cases ok_inj' h
      exact ⟨vg_extends_refl _, hd, trivial, Or.inl htr⟩
    rw [htr] at h
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, binop_arg_cls_spec0, binop_arg_cls_spec1,
      bind_ok] at h
    obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
    obtain ⟨av, vga⟩ := q1
    try simp only [uncurry_apply_pair] at h1
    obtain ⟨q2, hq2, h2⟩ := bind_eq_ok h1
    obtain ⟨bv, vgb⟩ := q2
    try simp only [uncurry_apply_pair] at h2
    obtain ⟨t8, ht8, h3⟩ := bind_eq_ok h2
    have e3 := ok_inj' h3
    simp only [Prod.mk.injEq] at e3
    obtain ⟨et8, eg⟩ := e3
    have ht8' : t8 = true := by revert et8; cases t8 <;> simp
    rw [ht8'] at ht8
    subst eg
    obtain ⟨ea, da, hau⟩ := atom_use_sound hq1 hd hv
    obtain ⟨eb, db, hbu⟩ := atom_use_sound hq2 da (vidsOK_extends ea hv)
    dsimp only at ea da hau eb db hbu
    refine ⟨vg_extends_trans ea eb, db, trivial, Or.inr ⟨d, c, op, a, bb, rfl, htr,
      fun G hG W o env regs haa hab => ?_⟩⟩
    obtain ⟨vbv, hne⟩ := bin_safe_any ht8 db env (atomVal o regs (binArgCls op c 0) a) (fun hva => by
      rw [extends_evI eb env (hau hva.1).1, atom_use_val hq1 hd hv hva.1
        (atomAgree_down (vg_extends_trans (vg_extends_trans ea eb) hG) haa)])
    rw [atom_use_val hq2 da (vidsOK_extends ea hv) vbv.1 (atomAgree_down (vg_extends_trans eb hG) hab)] at hne
    exact hne
  | _ => simp at h

theorem tgt_pure_c_sound {vg : ValGraph} {f : Func} {tvid : Pion.Array Std.I32} {b i : Std.I32}
    {q : Bool × ValGraph} (h : tgt_pure_c vg f tvid b i = ok q) (ht : q.1 = true) (hd : ValGraphDAG vg)
    (hv : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ B inst, f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ i.val ∧
      B.insts.val[i.val.toNat]? = some inst ∧ PureTgt q.2 tvid.val inst := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold tgt_pure_c at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨inst, hinst, h2⟩ := bind_eq_ok h1
  obtain ⟨hi0, hil, hiv⟩ := arr_get_ok hinst
  have hii : B.insts.val[i.val.toNat]? = some inst := by rw [List.getElem?_eq_getElem hil, hiv]
  obtain ⟨q3, hq3, h3⟩ := bind_eq_ok h2
  obtain ⟨t3, vg1⟩ := q3
  try simp only [uncurry_apply_pair] at h3
  cases t3 with
  | true => simp only [↓reduceIte] at h3; cases ok_inj' h3
  | false =>
  simp only [Bool.false_eq_true, ↓reduceIte] at h3
  obtain ⟨e1, d1, hnw, hcase⟩ := tgt_effect_c_false_sound hq3 hd hv
  obtain ⟨B4, hB4, h4⟩ := bind_eq_ok h3
  rw [hB] at hB4; cases ok_inj' hB4
  obtain ⟨inst5, hinst5, h5⟩ := bind_eq_ok h4
  rw [hinst] at hinst5; cases ok_inj' hinst5
  cases hcase with
  | inl hck =>
    -- no trapping division: nothing more is checked
    have hq : qg = vg1 := by
      cases inst with
      | Bin d c op a bb =>
        simp only [is_trapping_binop_spec, bind_ok] at h5
        simp only [TgtChecked] at hck
        rw [hck] at h5
        simp only [Bool.false_and, Bool.false_eq_true, ↓reduceIte, bind_ok] at h5
        exact (Prod.mk.inj (ok_inj' h5)).2.symm
      | Par _ _ _ => exact (Prod.mk.inj (ok_inj' h5)).2.symm
      | Un _ _ _ _ => exact (Prod.mk.inj (ok_inj' h5)).2.symm
      | _ => exact absurd hck (by simp [TgtChecked])
    subst hq
    exact ⟨e1, d1, B, inst, hBb, hi0, hii, hnw, Or.inl hck⟩
  | inr hbin =>
    obtain ⟨d, c, op, a, bb, rfl, htr, hsafe⟩ := hbin
    simp only [is_trapping_binop_spec, htr, Bool.true_and, bind_ok] at h5
    obtain ⟨t9, ht9, h6⟩ := bind_eq_ok h5
    obtain ⟨t11, ht11, h7⟩ := bind_eq_ok h6
    -- the value check, when the destination has a known value
    have hcond : t11 = true ↔ 0 ≤ d.val ∧ ∃ v, tvid.val[d.val.toNat]? = some v ∧ 0 ≤ v.val := by
      constructor
      · intro h11
        subst h11
        split at ht11
        · rename_i h9
          subst h9
          obtain ⟨w, hw, ht11⟩ := bind_eq_ok ht11
          obtain ⟨hw0, hwl, hwv⟩ := arr_get_ok hw
          have := ok_inj' ht11
          exact ⟨hw0, w, by rw [List.getElem?_eq_getElem hwl, hwv], by simpa [i32_le_iff] using this.symm⟩
        · cases ok_inj' ht11
      · rintro ⟨hd0, w, hw, hw0⟩
        have hdl : d.val.toNat < tvid.val.length := by
          by_contra hc; rw [List.getElem?_eq_none (by omega)] at hw; cases hw
        have h9 : t9 = true := by
          rw [ite_eq_left (by simpa [i32_le_iff] using hd0)] at ht9
          obtain ⟨n, hn, ht9⟩ := bind_eq_ok ht9
          obtain ⟨hn1, -⟩ := arr_length_ok hn
          rw [← ok_inj' ht9]
          simp only [decide_eq_true_eq, i32_lt_iff, hn1]
          omega
        subst h9
        simp only [↓reduceIte] at ht11
        obtain ⟨w', hw', ht11⟩ := bind_eq_ok ht11
        obtain ⟨_, hwl', hwv'⟩ := arr_get_ok hw'
        rw [List.getElem?_eq_getElem hwl', hwv'] at hw
        cases hw
        rw [← ok_inj' ht11]
        simpa [i32_le_iff] using hw0
    cases t11 with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at h7
      have hq : qg = vg1 := (Prod.mk.inj (ok_inj' h7)).2.symm
      subst hq
      refine ⟨e1, d1, B, _, hBb, hi0, hii, hnw, Or.inr ⟨d, c, op, a, bb, rfl, htr,
        fun o env regs => hsafe qg (vg_extends_refl _) o env regs, fun v hd0 hv' hv0 => ?_⟩⟩
      exact absurd (hcond.2 ⟨hd0, v, hv', hv0⟩) (by simp)
    | true =>
      simp only [↓reduceIte] at h7
      obtain ⟨vd, hvd, h8⟩ := bind_eq_ok h7
      obtain ⟨_, hvdl, hvdv⟩ := arr_get_ok hvd
      obtain ⟨B9, hB9, h9⟩ := bind_eq_ok h8
      rw [hB] at hB9; cases ok_inj' hB9
      obtain ⟨inst10, hinst10, h10⟩ := bind_eq_ok h9
      rw [hinst] at hinst10; cases ok_inj' hinst10
      obtain ⟨q11, hq11, h11⟩ := bind_eq_ok h10
      obtain ⟨r, vg2⟩ := q11
      try simp only [uncurry_apply_pair] at h11
      have e11 := ok_inj' h11
      simp only [Prod.mk.injEq] at e11
      obtain ⟨er, eg⟩ := e11
      subst eg
      have hvr : vd = r := by simpa using er
      subst hvr
      obtain ⟨e2, d2, h2v⟩ := eval_inst_sound hq11 d1 (vidsOK_extends e1 hv)
      dsimp only at e2 d2 h2v
      obtain ⟨hd0, w, hw, hw0⟩ := hcond.1 rfl
      have hwv : w = vd := by
        rw [List.getElem?_eq_getElem hvdl, hvdv] at hw; exact (Option.some.inj hw).symm
      subst hwv
      obtain ⟨hvalid, hpd | ⟨hl, -⟩⟩ := h2v hw0
      · refine ⟨vg_extends_trans e1 e2, d2, B, _, hBb, hi0, hii, hnw, Or.inr ⟨d, c, op, a, bb, rfl, htr,
          fun o env regs => hsafe _ e2 o env regs, fun v _ hv' _ => ?_⟩⟩
        rw [List.getElem?_eq_getElem hvdl, hvdv] at hv'
        cases hv'
        exact ⟨hvalid, hpd⟩
      · cases hl

theorem skip_tgt_pure_sound {vg : ValGraph} {f : Func} {tvid : Pion.Array Std.I32} {b x0 : Std.I32}
    {q : Std.I32 × ValGraph} (h : skip_tgt_pure vg f tvid b x0 = ok q) (hx0 : 0 ≤ x0.val)
    (hd : ValGraphDAG vg) (hv : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ B, f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ b.val ∧
      x0.val ≤ q.1.val ∧ (x0.val ≤ B.insts.val.length → q.1.val ≤ B.insts.val.length) ∧
      ∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < q.1.val.toNat →
        PureTgt q.2 tvid.val B.insts.val[i] := by
  have _ := hx0
  unfold skip_tgt_pure at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨hb0, hBl, hBv⟩ := arr_get_ok hB
  have hBb : f.blocks.val[b.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨n, hn, h2⟩ := bind_eq_ok h1
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  have h3 := pair_ok h2
  unfold skip_tgt_pure_loop0 at h3
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (x, vg) => skip_tgt_pure_loop0.body n f tvid b x vg)
    (fun x => x0.val ≤ x.1.val ∧ (x0.val ≤ B.insts.val.length → x.1.val ≤ B.insts.val.length) ∧
      vg_extends vg x.2 ∧ ValGraphDAG x.2 ∧
      ∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < x.1.val.toNat → PureTgt x.2 tvid.val B.insts.val[i])
    (fun y => x0.val ≤ y.1.val ∧ (x0.val ≤ B.insts.val.length → y.1.val ≤ B.insts.val.length) ∧
      vg_extends vg y.2 ∧ ValGraphDAG y.2 ∧
      ∀ i (hi : i < B.insts.val.length), x0.val.toNat ≤ i → i < y.1.val.toNat → PureTgt y.2 tvid.val B.insts.val[i])
    ?_ _ _ h3 ⟨le_refl _, fun h => h, vg_extends_refl _, hd, fun i _ h1 h2 => by dsimp only at h2; omega⟩
  · obtain ⟨a1, a2, a3, a4, a5⟩ := key
    exact ⟨a3, a4, B, hBb, hb0, a1, a2, a5⟩
  rintro ⟨x, vgx⟩ c ⟨hx1, hxl, hex, hdx, hall⟩ hc
  try dsimp only at hx1 hxl hex hdx hall hc
  unfold skip_tgt_pure_loop0.body at hc
  obtain ⟨q4, hq4, hc1⟩ := bind_eq_ok hc
  obtain ⟨t4, vg1⟩ := q4
  try simp only [uncurry_apply_pair] at hc1
  by_cases hlt : x < n
  · rw [ite_eq_left hlt] at hq4
    have hlt' : x.val < B.insts.val.length := by simpa [i32_lt_iff, hn1] using hlt
    have hq4' := pair_ok hq4
    cases t4 with
    | false =>
      simp only [Bool.false_eq_true, ↓reduceIte] at hc1
      rw [← ok_inj' hc1]
      obtain ⟨e1, d1⟩ : vg_extends vgx vg1 ∧ ValGraphDAG vg1 := by
        unfold tgt_pure_c at hq4'
        obtain ⟨B2, -, hq4'⟩ := bind_eq_ok hq4'
        obtain ⟨inst2, -, hq4'⟩ := bind_eq_ok hq4'
        obtain ⟨q5, hq5, hq4'⟩ := bind_eq_ok hq4'
        obtain ⟨t5, vg5⟩ := q5
        have hext5 : vg_extends vgx vg5 ∧ ValGraphDAG vg5 := by
          unfold tgt_effect_c at hq5
          cases inst2 with
          | Bin d c op a bb =>
            simp only [is_trapping_binop_spec, bind_ok] at hq5
            split at hq5
            · cases ok_inj' hq5; exact ⟨vg_extends_refl _, hdx⟩
            · simp only [binop_arg_cls_spec0, binop_arg_cls_spec1, bind_ok] at hq5
              obtain ⟨q1, hq1, hq5⟩ := bind_eq_ok hq5
              obtain ⟨av, vga⟩ := q1
              try simp only [uncurry_apply_pair] at hq5
              obtain ⟨q2, hq2, hq5⟩ := bind_eq_ok hq5
              obtain ⟨bv, vgb⟩ := q2
              try simp only [uncurry_apply_pair] at hq5
              obtain ⟨t8, -, hq5⟩ := bind_eq_ok hq5
              cases ok_inj' hq5
              have hvx : VidsOK vgx tvid.val := vidsOK_extends hex hv
              obtain ⟨ea, da, -⟩ := atom_use_sound hq1 hdx hvx
              obtain ⟨eb, db, -⟩ := atom_use_sound hq2 da (vidsOK_extends ea hvx)
              exact ⟨vg_extends_trans ea eb, db⟩
          | _ => cases ok_inj' hq5; exact ⟨vg_extends_refl _, hdx⟩
        try simp only [uncurry_apply_pair] at hq4'
        cases t5 with
        | true => simp only [↓reduceIte] at hq4'; cases ok_inj' hq4'; exact hext5
        | false =>
          simp only [Bool.false_eq_true, ↓reduceIte] at hq4'
          obtain ⟨B6, -, hq4'⟩ := bind_eq_ok hq4'
          obtain ⟨inst6, -, hq4'⟩ := bind_eq_ok hq4'
          split at hq4'
          · obtain ⟨t7, -, hq4'⟩ := bind_eq_ok hq4'
            obtain ⟨t9, -, hq4'⟩ := bind_eq_ok hq4'
            obtain ⟨t11, -, hq4'⟩ := bind_eq_ok hq4'
            split at hq4'
            · obtain ⟨vd, -, hq4'⟩ := bind_eq_ok hq4'
              obtain ⟨B9, -, hq4'⟩ := bind_eq_ok hq4'
              obtain ⟨inst9, -, hq4'⟩ := bind_eq_ok hq4'
              obtain ⟨q10, hq10, hq4'⟩ := bind_eq_ok hq4'
              obtain ⟨r, vg10⟩ := q10
              try simp only [uncurry_apply_pair] at hq4'
              have e := ok_inj' hq4'
              simp only [Prod.mk.injEq] at e
              rw [← e.2]
              obtain ⟨e10, d10, -⟩ := eval_inst_sound hq10 hext5.2 (vidsOK_extends (vg_extends_trans hex hext5.1) hv)
              exact ⟨vg_extends_trans hext5.1 e10, d10⟩
            · cases ok_inj' hq4'
          · cases ok_inj' hq4'
      exact ⟨hx1, hxl, vg_extends_trans hex e1, d1, fun i hi h1 h2 =>
        pureTgt_extends e1 (hall i hi h1 h2)⟩
    | true =>
      simp only [↓reduceIte] at hc1
      rw [← ok_inj' hc1]
      dsimp only
      obtain ⟨e1, d1, B', inst, hB', hx0', hinst, hpt⟩ :=
        tgt_pure_c_sound hq4' rfl hdx (vidsOK_extends hex hv)
      dsimp only at e1 d1 hpt
      rw [hBb] at hB'; cases hB'
      have hxs := i32_succ_val' hlt' hn2
      refine ⟨by omega, fun _ => by omega, vg_extends_trans hex e1, d1, fun i hi h1 h2 => ?_⟩
      by_cases hix : i = x.val.toNat
      · subst hix
        rw [List.getElem?_eq_getElem hi] at hinst
        cases hinst
        exact hpt
      · exact pureTgt_extends e1 (hall i hi h1 (by omega))
  · rw [ite_eq_right hlt] at hq4
    cases ok_inj' hq4
    simp only [Bool.false_eq_true, ↓reduceIte] at hc1
    rw [← ok_inj' hc1]
    exact ⟨hx1, hxl, hex, hdx, hall⟩

/-! ## Edges between blocks -/

theorem find_phi_spec {f : Func} {b d k : Std.I32} (h : find_phi f b d = ok k) (hk : 0 ≤ k.val) :
    ∃ B P, f.blocks.val[b.val.toNat]? = some B ∧ B.phis.val[k.val.toNat]? = some P ∧ P.dst = d := by
  unfold find_phi at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨n, hn, h2⟩ := bind_eq_ok h1
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h3⟩ := bind_eq_ok h2
  have key := scan_loop (fun k => find_phi_loop0.body n f b d k) B.phis.val.length
    (fun _ => True) (fun _ r => ∃ P, B.phis.val[r.val.toNat]? = some P ∧ P.dst = d) (fun _ => True)
    (by
      intro i c hi hc
      unfold find_phi_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < B.phis.val.length := by simpa [i32_lt_iff, hn1] using hlt
        obtain ⟨B2, hB2, hc⟩ := bind_eq_ok hc
        rw [hB] at hB2; cases ok_inj' hB2
        obtain ⟨P, hP, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
        left
        refine ⟨hlt', hn2, ?_⟩
        split at hc
        · rename_i hd
          left
          exact ⟨i, (ok_inj' hc).symm, P, by rw [List.getElem?_eq_getElem hPl, hPv], hd⟩
        · right; exact ⟨trivial, (ok_inj' hc).symm⟩
      · rename_i hge
        right
        exact ⟨by simpa [i32_lt_iff, hn1] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk' := key 0#i32 s hs (by simp)
  cases s with
  | inl r =>
    simp only at h3
    cases ok_inj' h3
    obtain ⟨i, -, -, ⟨P, hP, hd⟩, -⟩ := hk'
    exact ⟨B, P, by rw [List.getElem?_eq_getElem hBl, hBv], hP, hd⟩
  | inr g =>
    simp only at h3
    cases ok_inj' h3
    simp at hk

theorem vg_is_phi_of_spec {vg : ValGraph} {v blk : Std.I32} {r : Bool} (h : vg_is_phi_of vg v blk = ok r) :
    r = true ↔ ∃ c k, nodeAt vg v = some (.SPhi c blk k) := by
  unfold vg_is_phi_of at h
  obtain ⟨t, ht, h1⟩ := bind_eq_ok h
  obtain ⟨ht1, -⟩ := vg_valid_ok ht
  cases t with
  | false =>
    simp only [Bool.not_false, ↓reduceIte] at h1
    cases ok_inj' h1
    simp only [Bool.false_eq_true, false_iff, not_exists]
    intro c k hn
    exact absurd (ht1.2 (nodeAt_valid hn)) (by simp)
  | true =>
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h1
    have hvalid := ht1.1 rfl
    obtain ⟨node, hnode, h2⟩ := bind_eq_ok h1
    obtain ⟨_, hnl, hnv⟩ := arr_get_ok hnode
    have hna : nodeAt vg v = some node := by
      simp only [nodeAt, hvalid.1, ↓reduceIte]; rw [List.getElem?_eq_getElem hnl, hnv]
    rw [hna]
    cases node with
    | SPhi c b k =>
      simp only at h2
      cases ok_inj' h2
      simp only [beq_iff_eq, Option.some.injEq, SymNode.SPhi.injEq]
      constructor
      · rintro rfl; exact ⟨c, k, rfl, rfl, rfl⟩
      · rintro ⟨c', k', -, hb, -⟩; exact hb
    | _ => simp only at h2; cases ok_inj' h2; simp

theorem bm_has_true {cert : Cert} {tb sb : Std.I32} (h : bm_has cert tb sb = ok true) :
    ∃ j : Nat, cert.bm_t.val[j]? = some tb ∧ cert.bm_s.val[j]? = some sb := by
  unfold bm_has at h
  obtain ⟨n, -, h⟩ := bind_eq_ok h
  obtain ⟨q, -, h⟩ := bind_eq_ok h
  obtain ⟨lo1, hi1⟩ := q
  try simp only [uncurry_apply_pair] at h
  obtain ⟨s, hs, h2⟩ := bind_eq_ok h
  unfold bm_has_loop1 at hs
  have key := loop_ok_inv (fun j => bm_has_loop1.body n cert tb sb j) (fun _ => True)
    (fun r => match r with
      | .inl b => b = true → ∃ j : Nat, cert.bm_t.val[j]? = some tb ∧ cert.bm_s.val[j]? = some sb
      | .inr _ => True)
    (by
      intro j c _ hc
      unfold bm_has_loop1.body at hc
      obtain ⟨t4, -, hc⟩ := bind_eq_ok hc
      obtain ⟨t6, ht6, hc⟩ := bind_eq_ok hc
      split at hc
      · rename_i h6
        obtain ⟨t7, ht7, hc⟩ := bind_eq_ok hc
        obtain ⟨_, ht7l, ht7v⟩ := arr_get_ok ht7
        split at hc
        · rename_i he
          rw [← ok_inj' hc]
          intro _
          split at ht6
          · obtain ⟨t5, ht5, ht6⟩ := bind_eq_ok ht6
            obtain ⟨_, ht5l, ht5v⟩ := arr_get_ok ht5
            have := ok_inj' ht6
            subst this
            refine ⟨j.val.toNat, ?_, by rw [List.getElem?_eq_getElem ht7l, ht7v, he]⟩
            rw [List.getElem?_eq_getElem ht5l, ht5v, (i32_beq_iff _ _).1 h6]
          · cases ok_inj' ht6
            cases h6
        · rw [← ok_inj' hc]
          trivial
      · rw [← ok_inj' hc]
        trivial)
    _ _ hs trivial
  cases s with
  | inl b =>
    simp only at h2
    cases ok_inj' h2
    exact key rfl
  | inr g =>
    simp only at h2
    cases ok_inj' h2

theorem src_enter_scope_ok_sound {vg : ValGraph} {tgt : Func} {tvid : Pion.Array Std.I32} {tc sj : Std.I32}
    (h : src_enter_scope_ok vg tgt tvid tc sj = ok true) :
    ∃ B, tgt.blocks.val[tc.val.toNat]? = some B ∧ ∀ P ∈ B.phis.val, ∃ v, tvid.val[P.dst.val.toNat]? = some v ∧
      0 ≤ P.dst.val ∧ vid_mentions_blk vg v sj = ok false := by
  unfold src_enter_scope_ok at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨n, hn, h1⟩ := bind_eq_ok h1
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h2⟩ := bind_eq_ok h1
  have key := scan_loop (fun i => src_enter_scope_ok_loop0.body n B.phis tvid vg sj i) B.phis.val.length
    (fun k => ∀ hk : k < B.phis.val.length, ∃ v, tvid.val[B.phis.val[k].dst.val.toNat]? = some v ∧
      0 ≤ B.phis.val[k].dst.val ∧ vid_mentions_blk vg v sj = ok false)
    (fun _ r => r = false) (fun _ => True)
    (by
      intro i c hi hc
      unfold src_enter_scope_ok_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < B.phis.val.length := by simpa [i32_lt_iff, hn1] using hlt
        obtain ⟨P, hP, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
        obtain ⟨v, hv, hc⟩ := bind_eq_ok hc
        obtain ⟨hv0, hvl, hvv⟩ := arr_get_ok hv
        obtain ⟨t4, ht4, hc⟩ := bind_eq_ok hc
        left
        refine ⟨hlt', hn2, ?_⟩
        cases t4 with
        | true => simp only [↓reduceIte] at hc; left; exact ⟨false, (ok_inj' hc).symm, rfl⟩
        | false =>
          simp only [Bool.false_eq_true, ↓reduceIte] at hc
          right
          refine ⟨fun hk => ?_, (ok_inj' hc).symm⟩
          rw [hPv]
          exact ⟨v, by rw [List.getElem?_eq_getElem hvl, hvv], hv0, ht4⟩
      · rename_i hge
        right
        exact ⟨by simpa [i32_lt_iff, hn1] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 s hs (by simp)
  cases s with
  | inl r =>
    simp only at h2
    obtain ⟨i, -, -, hr, -⟩ := hk
    rw [hr] at h2; cases ok_inj' h2
  | inr g =>
    refine ⟨B, by rw [List.getElem?_eq_getElem hBl, hBv], fun P hP => ?_⟩
    obtain ⟨k, hk', rfl⟩ := List.getElem_of_mem hP
    exact hk.2 k (by simp) hk' hk'

/-- `absorb_ok`: on the edge from `pred`, each phi of target block `m` takes the value `tvid`
gives its destination. -/
theorem absorb_ok_sound {vg : ValGraph} {tgt : Func} {tvid : Pion.Array Std.I32} {m pred : Std.I32}
    {q : Bool × ValGraph} (h : absorb_ok vg tgt tvid m pred = ok q) (ht : q.1 = true)
    (hd : ValGraphDAG vg) (hv : VidsOK vg tvid.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ B, tgt.blocks.val[m.val.toNat]? = some B ∧
      ∀ P ∈ B.phis.val, ∃ a, phiArg P pred.val = some a ∧ ∃ v, tvid.val[P.dst.val.toNat]? = some v ∧
        0 ≤ P.dst.val ∧ Valid q.2 v ∧ AtomKnown q.2 tvid.val a ∧
        ∀ env, evI q.2 env v = maskC P.cls (atomSem q.2 env tvid.val a) := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold absorb_ok at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  have hBb : tgt.blocks.val[m.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨np, hnp, h2⟩ := bind_eq_ok h1
  obtain ⟨hnp1, hnp2⟩ := arr_length_ok hnp
  obtain ⟨s, hs, h3⟩ := bind_eq_ok h2
  unfold absorb_ok_loop0 at hs
  let Good : ValGraph → Phi → Prop := fun g P => ∃ a, phiArg P pred.val = some a ∧
    ∃ v, tvid.val[P.dst.val.toNat]? = some v ∧ 0 ≤ P.dst.val ∧ Valid g v ∧ AtomKnown g tvid.val a ∧
      ∀ env, evI g env v = maskC P.cls (atomSem g env tvid.val a)
  have good_mono : ∀ g g' P, vg_extends g g' → Good g P → Good g' P := by
    rintro g g' P e ⟨a, ha, v, hv1, hd0, hvv, hk, he⟩
    exact ⟨a, ha, v, hv1, hd0, extends_valid e hvv, atomKnown_extends e hk, fun env => by
      rw [extends_evI e env hvv, atomSem_extends e hk, he env]⟩
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (j, vg) => absorb_ok_loop0.body np tgt m pred tvid j vg)
    (fun x => 0 ≤ x.1.val ∧ vg_extends vg x.2 ∧ ValGraphDAG x.2 ∧
      ∀ j (hj : j < B.phis.val.length), j < x.1.val.toNat → Good x.2 B.phis.val[j])
    (fun r => match r with
      | .inl e => e.1 = true → vg_extends vg e.2 ∧ ValGraphDAG e.2 ∧ ∀ P ∈ B.phis.val, Good e.2 P
      | .inr y => vg_extends vg y.2 ∧ ValGraphDAG y.2 ∧ ∀ P ∈ B.phis.val, Good y.2 P)
    ?_ _ _ hs ⟨by simp, vg_extends_refl _, hd, fun j _ hj => by simp at hj⟩
  · cases s with
    | inl e =>
      rw [show e = (true, qg) from ok_inj' h3] at key
      obtain ⟨a1, a2, a3⟩ := key rfl
      exact ⟨a1, a2, B, hBb, a3⟩
    | inr y =>
      simp only at h3
      have e3 := ok_inj' h3
      simp only [Prod.mk.injEq] at e3
      obtain ⟨a1, a2, a3⟩ := key
      rw [← e3.2]
      exact ⟨a1, a2, B, hBb, a3⟩
  rintro ⟨jI, vgj⟩ c ⟨hj0, hej, hdj, hall⟩ hc
  try dsimp only at hj0 hej hdj hall hc
  unfold absorb_ok_loop0.body at hc
  by_cases hlt : jI < np
  · rw [ite_eq_left hlt] at hc
    have hlt' : jI.val < B.phis.val.length := by simpa [i32_lt_iff, hnp1] using hlt
    have hjs := i32_succ_val' hlt' hnp2
    obtain ⟨B2, hB2, hc1⟩ := bind_eq_ok hc
    rw [hB] at hB2; cases ok_inj' hB2
    obtain ⟨P, hP, hc2⟩ := bind_eq_ok hc1
    obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
    obtain ⟨B3, hB3, hc3⟩ := bind_eq_ok hc2
    rw [hB] at hB3; cases ok_inj' hB3
    obtain ⟨P3, hP3, hc4⟩ := bind_eq_ok hc3
    rw [hP] at hP3; cases ok_inj' hP3
    obtain ⟨ai, hai, hc5⟩ := bind_eq_ok hc4
    by_cases hain : ai < 0#i32
    · rw [ite_eq_left hain] at hc5; rw [← ok_inj' hc5]; intro hf; cases hf
    rw [ite_eq_right hain] at hc5
    have hai0 : 0 ≤ ai.val := by simpa [i32_lt_iff] using hain
    obtain ⟨B', P', -, hB', -, hP', hcase⟩ := phi_arm_index_spec hai
    rw [hBb] at hB'; cases hB'
    rw [List.getElem?_eq_getElem hPl, hPv] at hP'; cases hP'
    obtain ⟨-, hail, haip, haif⟩ : 0 ≤ ai.val ∧ ∃ hr : ai.val.toNat < P.arms.val.length,
        P.arms.val[ai.val.toNat].pred = pred ∧
        ∀ j < ai.val.toNat, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred ≠ pred := by
      rcases hcase with hc1 | ⟨hm, -⟩
      · exact hc1
      · omega
    have hphiarg : phiArg P pred.val = some P.arms.val[ai.val.toNat].value :=
      phiArg_idx hail (by rw [haip]) (fun j hj hjl e => haif j hj hjl (i32_ext e))
    obtain ⟨B7, hB7, hc6⟩ := bind_eq_ok hc5
    rw [hB] at hB7; cases ok_inj' hB7
    obtain ⟨P8, hP8, hc7⟩ := bind_eq_ok hc6
    rw [hP] at hP8; cases ok_inj' hP8
    obtain ⟨A, hA, hc8⟩ := bind_eq_ok hc7
    obtain ⟨_, hAl, hAv⟩ := arr_get_ok hA
    obtain ⟨t10, ht10, hc9⟩ := bind_eq_ok hc8
    cases t10 with
    | true => simp only [↓reduceIte] at hc9; rw [← ok_inj' hc9]; intro hf; cases hf
    | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at hc9
    obtain ⟨q1, hq1, hc10⟩ := bind_eq_ok hc9
    obtain ⟨v, vg1⟩ := q1
    try simp only [uncurry_apply_pair] at hc10
    obtain ⟨t14, ht14, hc11⟩ := bind_eq_ok hc10
    have hvj : VidsOK vgj tvid.val := vidsOK_extends hej hv
    obtain ⟨e1, d1, h1u⟩ := atom_use_sound hq1 hdj hvj
    dsimp only at e1 d1 h1u
    cases t14 with
    | true => simp only [↓reduceIte] at hc11; rw [← ok_inj' hc11]; intro hf; cases hf
    | false =>
    simp only [Bool.false_eq_true, ↓reduceIte] at hc11
    rw [← ok_inj' hc11]
    dsimp only
    have hv0 : 0 ≤ v.val := by
      by_contra hc
      rw [ite_eq_left (by simpa [i32_lt_iff] using hc)] at ht14
      cases ok_inj' ht14
    rw [ite_eq_right (by simpa [i32_lt_iff] using hv0)] at ht14
    obtain ⟨w, hw, ht14'⟩ := bind_eq_ok ht14
    obtain ⟨hw0, hwl, hwv⟩ := arr_get_ok hw
    have hwv' : w = v := by simpa using ok_inj' ht14'
    subst hwv'
    obtain ⟨vv, -, vk, vs⟩ := h1u hv0
    refine ⟨by omega, vg_extends_trans hej e1, d1, fun j hj hjl => ?_⟩
    by_cases hjj : j = jI.val.toNat
    · subst hjj
      rw [hPv]
      refine ⟨_, hphiarg, w, by rw [List.getElem?_eq_getElem hwl, hwv], hw0, vv, ?_, fun env => ?_⟩
      · rw [hAv]; exact atomKnown_extends e1 vk
      · rw [vs env, hAv, atomSem_extends e1 vk]
    · exact good_mono _ _ _ e1 (hall j hj (by omega))
  · rw [ite_eq_right hlt] at hc
    have hge : B.phis.val.length ≤ jI.val := by simpa [i32_lt_iff, hnp1] using hlt
    rw [← ok_inj' hc]
    refine ⟨hej, hdj, fun P hP => ?_⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hP
    exact hall j hj (by omega)

/-- The destination `d` of a phi of target block `sh`'s partner is also the destination of a
phi of source block `sh`, whose value is that phi's own leaf (`head_ok` / `edge_ok`). -/
def SrcPhiCase (G : ValGraph) (src : Func) (svid : List Std.I32) (sh d : Std.I32) : Prop :=
  0 ≤ d.val ∧ d.val.toNat < svid.length ∧ (∃ k, find_phi src sh d = ok k ∧ 0 ≤ k.val) ∧
    ∃ v, svid[d.val.toNat]? = some v ∧ ∃ c k', nodeAt G v = some (.SPhi c sh k')

theorem srcPhiCase_iff {G G' : ValGraph} (hp : vg_extends G G') {src : Func} {svid : List Std.I32}
    (hv : VidsOK G svid) {sh d : Std.I32} : SrcPhiCase G' src svid sh d ↔ SrcPhiCase G src svid sh d := by
  unfold SrcPhiCase
  constructor
  · rintro ⟨h0, hl, hk, v, hsv, c, k', hn⟩
    refine ⟨h0, hl, hk, v, hsv, c, k', ?_⟩
    rcases hv _ v hsv with rfl | hvv
    · simp [nodeAt] at hn
    · rw [← extends_nodeAt hp hvv]; exact hn
  · rintro ⟨h0, hl, hk, v, hsv, c, k', hn⟩
    exact ⟨h0, hl, hk, v, hsv, c, k', by rw [extends_nodeAt hp (nodeAt_valid hn)]; exact hn⟩

/-- The test `head_ok` and `edge_ok` make on destination `d`. -/
theorem phi_case_test {vg : ValGraph} {src : Func} {svid : Pion.Array Std.I32} {sh d k n : Std.I32} {t : Bool}
    (hn : Pion.Array.length svid = ok n)
    (hk : (if d < n then (do let x ← find_phi src sh d; ok x) else ok (-1)#i32) = ok k)
    (ht : (if k >= 0#i32 then (do let x ← Pion.Array.get svid d; let y ← vg_is_phi_of vg x sh; ok y)
           else ok false) = ok t) :
    (t = true ↔ SrcPhiCase vg src svid.val sh d) ∧ (t = true → find_phi src sh d = ok k ∧ 0 ≤ k.val) := by
  have hk1 := hk
  obtain ⟨hn1, -⟩ := arr_length_ok hn
  by_cases hdn : d < n
  · rw [ite_eq_left hdn] at hk1
    have hfk := bind_id_ok hk1
    by_cases hk0 : k >= 0#i32
    · rw [ite_eq_left hk0] at ht
      obtain ⟨x, hx, ht1⟩ := bind_eq_ok ht
      obtain ⟨hd0, hxl, hxv⟩ := arr_get_ok hx
      have hsv : svid.val[d.val.toNat]? = some x := by rw [List.getElem?_eq_getElem hxl, hxv]
      have hy := vg_is_phi_of_spec (bind_id_ok ht1)
      have hk0' : 0 ≤ k.val := by simpa [i32_le_iff] using hk0
      refine ⟨⟨fun htt => ⟨hd0, hxl, ⟨k, hfk, hk0'⟩, x, hsv, hy.1 htt⟩, fun hc => ?_⟩, fun _ => ⟨hfk, hk0'⟩⟩
      obtain ⟨-, -, -, v, hsv', hn'⟩ := hc
      rw [hsv] at hsv'; cases hsv'
      exact hy.2 hn'
    · rw [ite_eq_right hk0] at ht
      cases ok_inj' ht
      refine ⟨⟨fun h => (by cases h), fun hc => ?_⟩, fun h => (by cases h)⟩
      obtain ⟨-, -, ⟨k', hk', hk0'⟩, -⟩ := hc
      rw [hfk] at hk'; cases ok_inj' hk'
      exact absurd (by simpa [i32_le_iff] using hk0') hk0
  · rw [ite_eq_right hdn] at hk1
    cases ok_inj' hk1
    simp only [ge_iff_le] at ht
    rw [ite_eq_right (by decide)] at ht
    cases ok_inj' ht
    refine ⟨⟨fun h => (by cases h), fun hc => ?_⟩, fun h => (by cases h)⟩
    obtain ⟨-, hl, -⟩ := hc
    exact (hdn (by simp only [i32_lt_iff, hn1]; omega)).elim

theorem head_ok_sound {vg : ValGraph} {src : Func} {svid : Pion.Array Std.I32} {tgt : Func}
    {tvid : Pion.Array Std.I32} {sb tb : Std.I32} {q : Bool × ValGraph}
    (h : head_ok vg src svid tgt tvid sb tb = ok q) (ht : q.1 = true) :
    ∃ B, tgt.blocks.val[tb.val.toNat]? = some B ∧ ∀ P ∈ B.phis.val, ∃ v, tvid.val[P.dst.val.toNat]? = some v ∧
      0 ≤ P.dst.val ∧ Valid vg v ∧
      (SrcPhiCase vg src svid.val sb P.dst → ∃ k Bs SP, find_phi src sb P.dst = ok k ∧ 0 ≤ k.val ∧
        src.blocks.val[sb.val.toNat]? = some Bs ∧ Bs.phis.val[k.val.toNat]? = some SP ∧ SP.cls = P.cls ∧
        svid.val[P.dst.val.toNat]? = some v) ∧
      (¬ SrcPhiCase vg src svid.val sb P.dst → vid_mentions_blk vg v sb = ok false) := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold head_ok at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨np, hnp, h2⟩ := bind_eq_ok h1
  obtain ⟨hnp1, hnp2⟩ := arr_length_ok hnp
  obtain ⟨s, hs, h3⟩ := bind_eq_ok h2
  let Good : Phi → Prop := fun P => ∃ v, tvid.val[P.dst.val.toNat]? = some v ∧ 0 ≤ P.dst.val ∧ Valid vg v ∧
      (SrcPhiCase vg src svid.val sb P.dst → ∃ k Bs SP, find_phi src sb P.dst = ok k ∧ 0 ≤ k.val ∧
        src.blocks.val[sb.val.toNat]? = some Bs ∧ Bs.phis.val[k.val.toNat]? = some SP ∧ SP.cls = P.cls ∧
        svid.val[P.dst.val.toNat]? = some v) ∧
      (¬ SrcPhiCase vg src svid.val sb P.dst → vid_mentions_blk vg v sb = ok false)
  have key := scan_loop (fun j => head_ok_loop0.body np tgt tb tvid vg svid src sb j) B.phis.val.length
    (fun k => ∀ hk : k < B.phis.val.length, Good B.phis.val[k])
    (fun _ r => r.1 = false) (fun _ => True)
    (by
      intro i c hi hc
      unfold head_ok_loop0.body at hc
      by_cases hlt : i < np
      · rw [ite_eq_left hlt] at hc
        have hlt' : i.val < B.phis.val.length := by simpa [i32_lt_iff, hnp1] using hlt
        left
        refine ⟨hlt', hnp2, ?_⟩
        obtain ⟨B2, hB2, hc1⟩ := bind_eq_ok hc
        rw [hB] at hB2; cases ok_inj' hB2
        obtain ⟨P, hP, hc2⟩ := bind_eq_ok hc1
        obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
        obtain ⟨B3, hB3, hc3⟩ := bind_eq_ok hc2
        rw [hB] at hB3; cases ok_inj' hB3
        obtain ⟨P3, hP3, hc4⟩ := bind_eq_ok hc3
        rw [hP] at hP3; cases ok_inj' hP3
        obtain ⟨v, hv, hc5⟩ := bind_eq_ok hc4
        obtain ⟨hd0, hvl, hvv⟩ := arr_get_ok hv
        obtain ⟨t7, ht7, hc6⟩ := bind_eq_ok hc5
        obtain ⟨ht71, -⟩ := vg_valid_ok ht7
        cases t7 with
        | false => simp only [Bool.not_false, ↓reduceIte] at hc6; left; exact ⟨_, (ok_inj' hc6).symm, rfl⟩
        | true =>
        simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at hc6
        have hvalid := ht71.1 rfl
        obtain ⟨n8, hn8, hc6'⟩ := bind_eq_ok hc6
        obtain ⟨k, hk, hc7⟩ := bind_eq_ok hc6'
        obtain ⟨t13, ht13, hc8⟩ := bind_eq_ok hc7
        have htest := phi_case_test (src := src) (sh := sb) (d := P.dst) (vg := vg) hn8 hk ht13
        obtain ⟨sres, hsres, hc9⟩ := bind_eq_ok hc8
        cases sres with
        | inl r =>
          simp only at hc9
          left
          refine ⟨r, (ok_inj' hc9).symm, ?_⟩
          cases t13 with
          | true =>
            simp only [↓reduceIte] at hsres
            obtain ⟨Bs, -, hsres1⟩ := bind_eq_ok hsres
            obtain ⟨SP, -, hsres2⟩ := bind_eq_ok hsres1
            obtain ⟨t17, -, hsres3⟩ := bind_eq_ok hsres2
            cases t17
            · simp only [Bool.false_eq_true, ↓reduceIte] at hsres3; cases ok_inj' hsres3
            · simp only [↓reduceIte] at hsres3; cases ok_inj' hsres3; rfl
          | false =>
            simp only [Bool.false_eq_true, ↓reduceIte] at hsres
            obtain ⟨t18, -, hsres1⟩ := bind_eq_ok hsres
            cases t18
            · simp only [Bool.false_eq_true, ↓reduceIte] at hsres1
              obtain ⟨node, -, hsres2⟩ := bind_eq_ok hsres1
              cases node <;> (simp only at hsres2; cases ok_inj' hsres2)
              rfl
            · simp only [↓reduceIte] at hsres1; cases ok_inj' hsres1; rfl
        | inr u =>
          simp only at hc9
          right
          refine ⟨fun _ => ?_, (ok_inj' hc9).symm⟩
          rw [hPv]
          refine ⟨v, by rw [List.getElem?_eq_getElem hvl, hvv], hd0, hvalid, fun hcase => ?_, fun hncase => ?_⟩
          · have h13 : t13 = true := htest.1.2 hcase
            obtain ⟨hfk, hk0⟩ := htest.2 h13
            subst h13
            simp only [↓reduceIte] at hsres
            obtain ⟨Bs, hBs, hsres⟩ := bind_eq_ok hsres
            obtain ⟨_, hBsl, hBsv⟩ := arr_get_ok hBs
            obtain ⟨SP, hSP, hsres⟩ := bind_eq_ok hsres
            obtain ⟨_, hSPl, hSPv⟩ := arr_get_ok hSP
            obtain ⟨t17, ht17, hsres⟩ := bind_eq_ok hsres
            cases t17 with
            | true => simp only [↓reduceIte] at hsres; cases ok_inj' hsres
            | false =>
              refine ⟨k, Bs, SP, hfk, hk0, by rw [List.getElem?_eq_getElem hBsl, hBsv],
                by rw [List.getElem?_eq_getElem hSPl, hSPv], ?_⟩
              split at ht17
              · cases ok_inj' ht17
              · rename_i hcl
                obtain ⟨w, hw, ht17'⟩ := bind_eq_ok ht17
                obtain ⟨_, hwl, hwv⟩ := arr_get_ok hw
                have hvw : v = w := by simpa using ok_inj' ht17'
                subst hvw
                refine ⟨by simpa using hcl, by rw [List.getElem?_eq_getElem hwl, hwv]⟩
          · have h13 : t13 = false := by
              cases h' : t13
              · rfl
              · exact absurd (htest.1.1 h') hncase
            subst h13
            simp only [Bool.false_eq_true, ↓reduceIte] at hsres
            obtain ⟨t18, ht18, hsres⟩ := bind_eq_ok hsres
            cases t18 with
            | true => simp only [↓reduceIte] at hsres; cases ok_inj' hsres
            | false => exact ht18
      · rw [ite_eq_right hlt] at hc
        right
        exact ⟨by simpa [i32_lt_iff, hnp1] using hlt, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 s hs (by simp)
  cases s with
  | inl r =>
    obtain ⟨i, -, -, hr, -⟩ := hk
    rw [show r = (true, qg) from ok_inj' h3] at hr
    cases hr
  | inr g =>
    refine ⟨B, by rw [List.getElem?_eq_getElem hBl, hBv], fun P hP => ?_⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hP
    exact hk.2 j (by simp) hj hj

/-- What `edge_ok` certifies for target phi `P` of `th` on the edge `tp → th`, paired with the
source edge `sp → sh`. -/
def EdgePhi (G : ValGraph) (src : Func) (svid tvid : List Std.I32) (facts : List Fact)
    (sp tp sh : Std.I32) (P : Phi) : Prop :=
  ∃ ta, phiArg P tp.val = some ta ∧
    ∀ {W : Type} (o : WorldOracle W) (env : SymEnv) (sregs tregs : Nat → BitVec 64) (Bsp : Block),
      0 ≤ sp.val → src.blocks.val[sp.val.toNat]? = some Bsp →
      CondAgree G env svid o sregs Bsp.term → EdgeTaken o sregs Bsp.term sh →
      (∀ fb ∈ facts, fb.blk = sp → FactOK G env fb) → AtomAgree G env tvid o tregs ta →
      (SrcPhiCase G src svid sh P.dst → ∃ k Bs SP sa, find_phi src sh P.dst = ok k ∧ 0 ≤ k.val ∧
        src.blocks.val[sh.val.toNat]? = some Bs ∧ Bs.phis.val[k.val.toNat]? = some SP ∧
        phiArg SP sp.val = some sa ∧
        (AtomAgree G env svid o sregs sa → atomVal o tregs P.cls ta = atomVal o sregs P.cls sa)) ∧
      (¬ SrcPhiCase G src svid sh P.dst → ∀ v, tvid[P.dst.val.toNat]? = some v → Valid G v →
        evI G env v = atomVal o tregs P.cls ta)

theorem edge_ok_sound {vg : ValGraph} {src : Func} {svid : Pion.Array Std.I32} {facts : Pion.Array Fact}
    {tgt : Func} {tvid : Pion.Array Std.I32} {sp tp sh th : Std.I32} {q : Bool × ValGraph}
    (h : edge_ok vg src svid facts tgt tvid sp tp sh th = ok q) (ht : q.1 = true) (hd : ValGraphDAG vg)
    (hvs : VidsOK vg svid.val) (hvt : VidsOK vg tvid.val) (hfv : ∀ fb ∈ facts.val, Valid vg fb.vid) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ B, tgt.blocks.val[th.val.toNat]? = some B ∧
      ∀ G, vg_extends q.2 G → ∀ P ∈ B.phis.val, EdgePhi G src svid.val tvid.val facts.val sp tp sh P := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold edge_ok at h
  obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
  obtain ⟨fs, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h1
  obtain ⟨e1, d1, hfs⟩ := edge_fact_set_sound hq1 hd hvs
  dsimp only at e1 d1 hfs
  obtain ⟨B, hB, h2⟩ := bind_eq_ok h1
  obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
  have hBb : tgt.blocks.val[th.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
  obtain ⟨np, hnp, h3⟩ := bind_eq_ok h2
  obtain ⟨hnp1, hnp2⟩ := arr_length_ok hnp
  obtain ⟨s, hs, h4⟩ := bind_eq_ok h3
  unfold edge_ok_loop0 at hs
  -- the edge's facts hold on a run of the edge
  have hfsG : ∀ G, vg_extends vg1 G → ∀ {W : Type} (o : WorldOracle W) (env : SymEnv)
      (sregs : Nat → BitVec 64) (Bsp : Block), 0 ≤ sp.val → src.blocks.val[sp.val.toNat]? = some Bsp →
      CondAgree G env svid.val o sregs Bsp.term → EdgeTaken o sregs Bsp.term sh →
      (∀ fb ∈ facts.val, fb.blk = sp → FactOK G env fb) → FactsHold G env fs.val := by
    intro G hG W o env sregs Bsp hsp0 hBsp hca het hfb
    have hca' : CondAgree vg env svid.val o sregs Bsp.term := by
      cases hT : Bsp.term with
      | Jnz c _ _ => rw [hT] at hca; exact atomAgree_down (vg_extends_trans e1 hG) hca
      | _ => trivial
    have hfb' : ∀ fb ∈ facts.val, fb.blk = sp → FactOK vg env fb := by
      intro fb hm he
      obtain ⟨hvG, hz, hnz⟩ := hfb fb hm he
      have hvv := hfv fb hm
      rw [extends_evI (vg_extends_trans e1 hG) env hvv] at hz hnz
      exact ⟨hvv, hz, hnz⟩
    exact factsHold_extends hG (hfs Bsp hsp0 hBsp o sregs env hca' het hfb')
  let Good : ValGraph → Phi → Prop := fun g P => ∀ G, vg_extends g G →
    EdgePhi G src svid.val tvid.val facts.val sp tp sh P
  have good_mono : ∀ g g' P, vg_extends g g' → Good g P → Good g' P :=
    fun g g' P e hg G hG => hg G (vg_extends_trans e hG)
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
      match x with | (j, vg) => edge_ok_loop0.body np tgt th tp tvid svid src sh sp fs j vg)
    (fun x => 0 ≤ x.1.val ∧ vg_extends vg1 x.2 ∧ ValGraphDAG x.2 ∧
      ∀ j (hj : j < B.phis.val.length), j < x.1.val.toNat → Good x.2 B.phis.val[j])
    (fun r => match r with
      | .inl e => e.1 = false
      | .inr y => vg_extends vg1 y.2 ∧ ValGraphDAG y.2 ∧ ∀ P ∈ B.phis.val, Good y.2 P)
    ?_ _ _ hs ⟨by simp, vg_extends_refl _, d1, fun j _ hj => by simp at hj⟩
  · cases s with
    | inl e =>
      simp only at h4
      rw [show e = (true, qg) from ok_inj' h4] at key
      cases key
    | inr y =>
      obtain ⟨j1, vg2⟩ := y
      simp only at h4
      have e4 := ok_inj' h4
      simp only [Prod.mk.injEq] at e4
      obtain ⟨a1, a2, a3⟩ := key
      rw [← e4.2]
      exact ⟨vg_extends_trans e1 a1, a2, B, hBb, fun G hG P hP => a3 P hP G hG⟩
  rintro ⟨jI, vgj⟩ c ⟨hj0, hej, hdj, hall⟩ hc
  try dsimp only at hj0 hej hdj hall hc
  unfold edge_ok_loop0.body at hc
  by_cases hlt : jI < np
  · rw [ite_eq_left hlt] at hc
    have hlt' : jI.val < B.phis.val.length := by simpa [i32_lt_iff, hnp1] using hlt
    have hjs := i32_succ_val' hlt' hnp2
    obtain ⟨B2, hB2, hc1⟩ := bind_eq_ok hc
    rw [hB] at hB2; cases ok_inj' hB2
    obtain ⟨P, hP, hc2⟩ := bind_eq_ok hc1
    obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
    obtain ⟨B3, hB3, hc3⟩ := bind_eq_ok hc2
    rw [hB] at hB3; cases ok_inj' hB3
    obtain ⟨P3, hP3, hc4⟩ := bind_eq_ok hc3
    rw [hP] at hP3; cases ok_inj' hP3
    obtain ⟨ai, hai, hc5⟩ := bind_eq_ok hc4
    by_cases hain : ai < 0#i32
    · rw [ite_eq_left hain] at hc5; rw [← ok_inj' hc5]
    rw [ite_eq_right hain] at hc5
    obtain ⟨B', P', -, hB', -, hP', hcase⟩ := phi_arm_index_spec hai
    rw [hBb] at hB'; cases hB'
    rw [List.getElem?_eq_getElem hPl, hPv] at hP'; cases hP'
    obtain ⟨-, hail, haip, haif⟩ : 0 ≤ ai.val ∧ ∃ hr : ai.val.toNat < P.arms.val.length,
        P.arms.val[ai.val.toNat].pred = tp ∧
        ∀ j < ai.val.toNat, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred ≠ tp := by
      rcases hcase with hc1 | ⟨hm, -⟩
      · exact hc1
      · have : ¬ ai < 0#i32 := hain; simp at this; omega
    have hphiarg : phiArg P tp.val = some P.arms.val[ai.val.toNat].value :=
      phiArg_idx hail (by rw [haip]) (fun j hj hjl e => haif j hj hjl (i32_ext e))
    obtain ⟨B9, hB9, hc6⟩ := bind_eq_ok hc5
    rw [hB] at hB9; cases ok_inj' hB9
    obtain ⟨P10, hP10, hc7⟩ := bind_eq_ok hc6
    rw [hP] at hP10; cases ok_inj' hP10
    obtain ⟨A, hA, hc8⟩ := bind_eq_ok hc7
    obtain ⟨_, hAl, hAv⟩ := arr_get_ok hA
    obtain ⟨q11, hq11, hc9⟩ := bind_eq_ok hc8
    obtain ⟨tv, vg1'⟩ := q11
    try simp only [uncurry_apply_pair] at hc9
    have hvjt : VidsOK vgj tvid.val := vidsOK_extends (vg_extends_trans e1 hej) hvt
    have hvjs : VidsOK vgj svid.val := vidsOK_extends (vg_extends_trans e1 hej) hvs
    obtain ⟨e11, d11, h11u⟩ := atom_use_sound hq11 hdj hvjt
    dsimp only at e11 d11 h11u
    obtain ⟨n14, hn14, hc10⟩ := bind_eq_ok hc9
    obtain ⟨k, hk, hc11⟩ := bind_eq_ok hc10
    obtain ⟨sv, hsv, hc12⟩ := bind_eq_ok hc11
    obtain ⟨hsv0, hsvl, hsvv⟩ := arr_get_ok hsv
    obtain ⟨t20, ht20, hc13⟩ := bind_eq_ok hc12
    have htest := phi_case_test (src := src) (sh := sh) (d := P.dst) (vg := vg1') hn14 hk ht20
    obtain ⟨sres, hsres, hc14⟩ := bind_eq_ok hc13
    -- the source value compared on this phi
    have hsres' : (∃ e, sres = .inl e ∧ e.1 = false) ∨ ∃ sv2 vg3, sres = .inr (sv2, vg3) ∧
        vg_extends vg1' vg3 ∧ ValGraphDAG vg3 ∧
        (t20 = true → ∃ Bs SP sa, src.blocks.val[sh.val.toNat]? = some Bs ∧ Bs.phis.val[k.val.toNat]? = some SP ∧
          phiArg SP sp.val = some sa ∧ (0 ≤ sv2.val → AtomKnown vg3 svid.val sa ∧
            ∀ env, evI vg3 env sv2 = maskC P.cls (atomSem vg3 env svid.val sa))) ∧
        (t20 = false → sv2 = sv ∧ vg3 = vg1') := by
      cases t20 with
      | true =>
        simp only [↓reduceIte] at hsres
        obtain ⟨sa, hsa, hs1⟩ := bind_eq_ok hsres
        by_cases hsan : sa < 0#i32
        · rw [ite_eq_left hsan] at hs1; left; exact ⟨_, (ok_inj' hs1).symm, rfl⟩
        rw [ite_eq_right hsan] at hs1
        obtain ⟨Bs', SP', -, hBs', -, hSP', hcs⟩ := phi_arm_index_spec hsa
        obtain ⟨-, hsal, hsap, hsaf⟩ : 0 ≤ sa.val ∧ ∃ hr : sa.val.toNat < SP'.arms.val.length,
            SP'.arms.val[sa.val.toNat].pred = sp ∧
            ∀ j < sa.val.toNat, ∀ hj : j < SP'.arms.val.length, SP'.arms.val[j].pred ≠ sp := by
          rcases hcs with hc1 | ⟨hm, -⟩
          · exact hc1
          · have : ¬ sa < 0#i32 := hsan; simp at this; omega
        obtain ⟨Bs, hBs, hs2⟩ := bind_eq_ok hs1
        obtain ⟨_, hBsl, hBsv⟩ := arr_get_ok hBs
        rw [List.getElem?_eq_getElem hBsl, hBsv] at hBs'
        have eB : Bs = Bs' := Option.some.inj hBs'
        subst eB
        obtain ⟨SP, hSP, hs3⟩ := bind_eq_ok hs2
        obtain ⟨_, hSPl, hSPv⟩ := arr_get_ok hSP
        rw [List.getElem?_eq_getElem hSPl, hSPv] at hSP'
        have eS : SP = SP' := Option.some.inj hSP'
        subst eS
        obtain ⟨SA, hSA, hs4⟩ := bind_eq_ok hs3
        obtain ⟨_, hSAl, hSAv⟩ := arr_get_ok hSA
        obtain ⟨q2, hq2, hs5⟩ := bind_eq_ok hs4
        obtain ⟨sv1, vg2⟩ := q2
        try simp only [uncurry_apply_pair] at hs5
        right
        refine ⟨sv1, vg2, (ok_inj' hs5).symm, ?_⟩
        obtain ⟨e2, d2, h2u⟩ := atom_use_sound hq2 d11 (vidsOK_extends e11 hvjs)
        dsimp only at e2 d2 h2u
        have hphis : phiArg SP sp.val = some SP.arms.val[sa.val.toNat].value :=
          phiArg_idx hsal (by rw [hsap]) (fun j hj hjl e => hsaf j hj hjl (i32_ext e))
        refine ⟨e2, d2, fun _ => ⟨Bs, SP, _, by rw [List.getElem?_eq_getElem hBsl, hBsv],
          by rw [List.getElem?_eq_getElem hSPl, hSPv], hphis, fun hs10 => ?_⟩, fun h => (by cases h)⟩
        obtain ⟨-, -, hk2, hval2⟩ := h2u hs10
        rw [← hSAv] at hk2 hval2
        exact ⟨atomKnown_extends e2 hk2, fun env => by rw [hval2 env, atomSem_extends e2 hk2]⟩
      | false =>
        simp only [Bool.false_eq_true, ↓reduceIte] at hsres
        right
        exact ⟨sv, vg1', (ok_inj' hsres).symm, vg_extends_refl _, d11, fun h => (by cases h), fun _ => ⟨rfl, rfl⟩⟩
    rcases hsres' with ⟨e, rfl, he⟩ | ⟨sv2, vg3, rfl, e3, d3, hS, hT⟩
    · simp only at hc14; rw [← ok_inj' hc14]; exact he
    simp only at hc14
    obtain ⟨q28, hq28, hc15⟩ := bind_eq_ok hc14
    obtain ⟨t28, vg4⟩ := q28
    try simp only [uncurry_apply_pair] at hc15
    cases t28 with
    | false => simp only [Bool.not_false, ↓reduceIte] at hc15; rw [← ok_inj' hc15]
    | true =>
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at hc15
    rw [← ok_inj' hc15]
    dsimp only
    obtain ⟨e4, d4, vsv2, vtv, heq⟩ := eq_under_sound hq28 d3
    have E14 : vg_extends vgj vg4 := vg_extends_trans e11 (vg_extends_trans e3 e4)
    refine ⟨by omega, vg_extends_trans hej E14, d4, fun j hj hjl => ?_⟩
    by_cases hjj : j = jI.val.toNat
    · subst hjj
      rw [hPv]
      intro G hG
      refine ⟨_, hphiarg, fun o env sregs tregs Bsp hsp0 hBsp hca het hfb hta => ?_⟩
      have hfsh := hfsG G (vg_extends_trans hej (vg_extends_trans E14 hG)) o env sregs Bsp hsp0 hBsp hca het hfb
      have hsv2tv := heq G env hG hfsh
      have htv0 : 0 ≤ tv.val := vtv.1
      obtain ⟨vtv1, -, -, -⟩ := h11u htv0
      have htvv : evI vg3 env tv = atomVal o tregs P.cls P.arms.val[ai.val.toNat].value := by
        rw [extends_evI e3 env vtv1, atom_use_val hq11 hdj hvjt htv0
          (atomAgree_down (vg_extends_trans E14 hG) (by rw [← hAv]; exact hta))]
        rw [hAv]
      have hiff := srcPhiCase_iff (vg_extends_trans e3 (vg_extends_trans e4 hG))
        (vidsOK_extends e11 hvjs) (src := src) (sh := sh) (d := P.dst)
      refine ⟨fun hcase => ?_, fun hncase => ?_⟩
      · have h20 : t20 = true := htest.1.2 (hiff.1 hcase)
        obtain ⟨hfk, hk0⟩ := htest.2 h20
        obtain ⟨Bs, SP, sa, hBs, hSP, hsa, hval⟩ := hS h20
        refine ⟨k, Bs, SP, sa, hfk, hk0, hBs, hSP, hsa, fun hsag => ?_⟩
        obtain ⟨hka, hevs⟩ := hval vsv2.1
        rw [← htvv, ← hsv2tv, hevs env, atomVal_eq (atomKnown_extends (vg_extends_trans e4 hG) hka) hsag,
          atomSem_extends (vg_extends_trans e4 hG) hka]
      · have h20 : t20 = false := by
          cases h' : t20
          · rfl
          · exact absurd (hiff.2 (htest.1.1 h')) hncase
        obtain ⟨rfl, rfl⟩ := hT h20
        intro v hv hvG
        rw [List.getElem?_eq_getElem hsvl, hsvv] at hv
        cases hv
        rw [extends_evI (vg_extends_trans e4 hG) env vsv2, hsv2tv, htvv]
    · exact good_mono _ _ _ E14 (hall j hj (by omega))
  · rw [ite_eq_right hlt] at hc
    have hge : B.phis.val.length ≤ jI.val := by simpa [i32_lt_iff, hnp1] using hlt
    rw [← ok_inj' hc]
    refine ⟨hej, hdj, fun P hP => ?_⟩
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hP
    exact hall j hj (by omega)

theorem next_ok_true {vg : ValGraph} {src : Func} {svid : Pion.Array Std.I32} {tgt : Func} {cert : Cert}
    {i sp tp sh th : Std.I32} {q : Bool × ValGraph}
    (h : next_ok vg src svid tgt cert i sp tp sh th = ok q) (ht : q.1 = true) :
    ∃ p, 0 ≤ i.val ∧ cert.pairs.val[i.val.toNat]? = some p ∧ p.sb = sh ∧ p.tb = th ∧
      edge_ok vg src svid cert.facts tgt cert.tvid sp tp sh th = ok q := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold next_ok at h
  obtain ⟨t1, ht1, h1⟩ := bind_eq_ok h
  obtain ⟨t3, ht3, h2⟩ := bind_eq_ok h1
  obtain ⟨t5, ht5, h3⟩ := bind_eq_ok h2
  cases t5 with
  | false => simp only [Bool.false_eq_true, ↓reduceIte] at h3; cases ok_inj' h3
  | true =>
  simp only [↓reduceIte] at h3
  cases t3 with
  | false => simp only [Bool.false_eq_true, ↓reduceIte] at ht5; cases ok_inj' ht5
  | true =>
  cases t1 with
  | false => simp only [Bool.false_eq_true, ↓reduceIte] at ht3; cases ok_inj' ht3
  | true =>
  simp only [↓reduceIte] at ht1 ht3 ht5
  have hi0 : 0 ≤ i.val := by
    by_contra hc
    rw [ite_eq_right (by simpa [i32_le_iff] using hc)] at ht1
    cases ok_inj' ht1
  obtain ⟨p, hp, ht3'⟩ := bind_eq_ok ht3
  obtain ⟨_, hpl, hpv⟩ := arr_get_ok hp
  obtain ⟨p', hp', ht5'⟩ := bind_eq_ok ht5
  rw [hp] at hp'; cases ok_inj' hp'
  refine ⟨p, hi0, by rw [List.getElem?_eq_getElem hpl, hpv], by simpa using ok_inj' ht3',
    by simpa using ok_inj' ht5', pair_ok h3⟩

theorem cmp_zero_sound {vg : ValGraph} {c : Std.I32} {q : Std.I32 × ValGraph} (h : cmp_zero vg c = ok q)
    (hd : ValGraphDAG vg) (hc : Valid vg c ∨ c.val < 0) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      (Valid vg c → Valid q.2 q.1 ∧ ∀ env, evI q.2 env q.1 = b2v (decide (maskC .W (evI vg env c) = 0))) ∧
      (¬ Valid vg c → q.1.val < 0) := by
  unfold cmp_zero at h
  obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
  obtain ⟨z, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h1
  have h2 := pair_ok h1
  obtain ⟨e1, d1, vz, -, -, valz⟩ := konst_facts hd hq1
  by_cases hvc : Valid vg c
  · obtain ⟨e2, d2, v2, -, val2⟩ := vg_canon_bin_sound h2 d1 (extends_valid e1 hvc) vz (by simp [BinArgOK, isCmp])
    refine ⟨vg_extends_trans e1 e2, d2, fun _ => ⟨v2, fun env => ?_⟩, fun h => absurd hvc h⟩
    apply val2 env
    simp only [evalBin, valz env, extends_evI e1 env hvc]
    congr 3
  · have hneg : c.val < 0 := hc.resolve_left hvc
    have hinv : ¬ (Valid vg1 c ∧ Valid vg1 z) := fun h' => by have := h'.1.1; omega
    rw [vg_canon_bin_invalid h2 hinv]
    exact ⟨e1, d1, fun h => absurd h hvc, fun _ => by simp⟩

theorem edgeTaken_unique {W : Type} {o : WorldOracle W} {regs : Nat → BitVec 64} {t : Term} {s1 s2 : Std.I32}
    (h1 : EdgeTaken o regs t s1) (h2 : EdgeTaken o regs t s2) : s1 = s2 := by
  cases t with
  | Jmp d => simp only [EdgeTaken] at h1 h2; rw [h1, h2]
  | Jnz a d1 d2 => simp only [EdgeTaken] at h1 h2; rw [h1, h2]
  | _ => exact absurd h1 (by simp [EdgeTaken])

theorem next_ok_ext {g : ValGraph} {src : Func} {tgt : Func} {cert : Cert} {i sp tp sh th : Std.I32}
    {g' : ValGraph} (h : next_ok g src cert.svid tgt cert i sp tp sh th = ok (true, g')) (hd : ValGraphDAG g)
    (hvs : VidsOK g cert.svid.val) (hvt : VidsOK g cert.tvid.val) (hfv : ∀ fb ∈ cert.facts.val, Valid g fb.vid) :
    vg_extends g g' ∧ ValGraphDAG g' := by
  obtain ⟨p, -, -, -, -, he⟩ := next_ok_true h rfl
  obtain ⟨e, d, -⟩ := edge_ok_sound he rfl hd hvs hvt hfv
  exact ⟨e, d⟩

/-- What `check_end` certifies about the terminators of a pair's last blocks. -/
def EndOK (src tgt : Func) (cert : Cert) (vg q2 : ValGraph) {W : Type} (o : WorldOracle W)
    (sregs tregs : Nat → BitVec 64) (sc tc : Std.I32) (Bs Bt : Block) : Prop :=
  (∃ h c a c' a', Bs.term = .Ret h c a ∧ Bt.term = .Ret h c' a' ∧
    (h = true → c = c' ∧ atomVal o sregs c a = atomVal o tregs c' a')) ∨
  (Bs.term = .Hlt ∧ Bt.term = .Hlt) ∨
  ((∃ sj, EdgeTaken o sregs Bs.term sj) ∧
  ∀ sj, EdgeTaken o sregs Bs.term sj → ∃ tj i g g', EdgeTaken o tregs Bt.term tj ∧
    next_ok g src cert.svid tgt cert i sc tc sj tj = ok (true, g') ∧ vg_extends vg g ∧ ValGraphDAG g ∧
    vg_extends g' q2)

theorem check_end_sound {vg : ValGraph} {src tgt : Func} {cert : Cert} {fs : Pion.Array Fact}
    {sc tc : Std.I32} {fin : EndCert} {q : Bool × ValGraph}
    (h : check_end vg src tgt cert fs sc tc fin = ok q) (ht : q.1 = true) (hd : ValGraphDAG vg)
    (hvs : VidsOK vg cert.svid.val) (hvt : VidsOK vg cert.tvid.val)
    (hfv : ∀ fb ∈ cert.facts.val, Valid vg fb.vid) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ ∃ Bs Bt, src.blocks.val[sc.val.toNat]? = some Bs ∧ 0 ≤ sc.val ∧
      tgt.blocks.val[tc.val.toNat]? = some Bt ∧ 0 ≤ tc.val ∧
      ∀ G, vg_extends q.2 G → ∀ {W : Type} (o : WorldOracle W) (env : SymEnv) (sregs tregs : Nat → BitVec 64),
        FactsHold G env fs.val → TermAgree G env cert.svid.val o sregs Bs.term →
        TermAgree G env cert.tvid.val o tregs Bt.term → EndOK src tgt cert vg q.2 o sregs tregs sc tc Bs Bt := by
  obtain ⟨qb, qg⟩ := q
  simp only at ht
  subst ht
  unfold check_end at h
  obtain ⟨q1, hq1, h1⟩ := bind_eq_ok h
  obtain ⟨sv, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h1
  obtain ⟨q2, hq2, h2⟩ := bind_eq_ok h1
  obtain ⟨tv, vg2⟩ := q2
  try simp only [uncurry_apply_pair] at h2
  rw [tgt_view_c_eq] at hq2
  obtain ⟨e1, d1, Bs, hBs, hsc0, hsj, hsv⟩ := src_view_sound hq1 hd hvs
  obtain ⟨e2, d2, Bt, hBt, htc0, htj, htv⟩ := src_view_sound hq2 d1 (vidsOK_extends e1 hvt)
  dsimp only at e1 d1 hsj hsv e2 d2 htj htv
  have E2 : vg_extends vg vg2 := vg_extends_trans e1 e2
  have hvs2 : VidsOK vg2 cert.svid.val := vidsOK_extends E2 hvs
  have hvt2 : VidsOK vg2 cert.tvid.val := vidsOK_extends E2 hvt
  have hfv2 : ∀ fb ∈ cert.facts.val, Valid vg2 fb.vid := fun fb hm => extends_valid E2 (hfv fb hm)
  -- the views, once the facts and the atoms are known to hold
  have views : ∀ G, vg_extends vg2 G → ∀ {W : Type} (o : WorldOracle W) (env : SymEnv) (sregs tregs : Nat → BitVec 64),
      FactsHold G env fs.val → TermAgree G env cert.svid.val o sregs Bs.term →
      TermAgree G env cert.tvid.val o tregs Bt.term →
      ViewOK G o sregs env Bs.term sv ∧ ViewOK G o tregs env Bt.term tv := fun G hG W o env sregs tregs hfs hs ht =>
    ⟨hsv G (vg_extends_trans e2 hG) o sregs env hfs hs, htv G hG o tregs env hfs ht⟩
  have hb2v : ∀ b : Bool, b2v b ≠ 0 ↔ b = true := by intro b; cases b <;> simp [b2v]
  have hmW : ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (a : Atom),
      maskC .W (atomVal o regs .W a) = atomVal o regs .W a := fun o regs a => maskC_idem _ _
  cases fin with
  | EndRet =>
    cases sv with
    | VRet sh scls svv =>
      cases tv with
      | VRet th tcls tvv =>
        simp only at h2
        by_cases hst : sh = th
        · rw [ite_eq_left hst] at h2
          subst hst
          cases sh with
          | false =>
            simp only [Bool.not_false, ↓reduceIte] at h2
            cases ok_inj' h2
            refine ⟨E2, d2, Bs, Bt, hBs, hsc0, hBt, htc0, fun G hG W o env sregs tregs hfs hts htt => Or.inl ?_⟩
            obtain ⟨⟨a, hsa, -⟩, ⟨a', hta, -⟩⟩ := views G hG o env sregs tregs hfs hts htt
            exact ⟨false, scls, a, tcls, a', hsa, hta, fun h => (by cases h)⟩
          | true =>
            simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h2
            by_cases hcl : scls = tcls
            · rw [ite_eq_left (by simp [hcl])] at h2
              subst hcl
              have h3 := pair_ok h2
              obtain ⟨e3, d3⟩ := eq_under_ext h3 d2
              obtain ⟨-, -, vsv, vtv, heq⟩ := eq_under_sound h3 d2
              refine ⟨vg_extends_trans E2 e3, d3, Bs, Bt, hBs, hsc0, hBt, htc0,
                fun G hG W o env sregs tregs hfs hts htt => Or.inl ?_⟩
              have E3 := vg_extends_trans e3 hG
              obtain ⟨⟨a, hsa, hs⟩, ⟨a', hta, ht'⟩⟩ := views G E3 o env sregs tregs hfs hts htt
              refine ⟨true, scls, a, scls, a', hsa, hta, fun _ => ⟨rfl, ?_⟩⟩
              rw [← hs rfl (extends_valid E3 vsv), ← ht' rfl (extends_valid E3 vtv),
                extends_evI E3 env vsv, extends_evI E3 env vtv]
              exact heq G env hG hfs
            · rw [ite_eq_right (by simp [hcl])] at h2; cases ok_inj' h2
        · rw [ite_eq_right hst] at h2; cases ok_inj' h2
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2
  | EndHlt =>
    cases sv with
    | VHlt =>
      cases tv with
      | VHlt =>
        simp only at h2
        cases ok_inj' h2
        refine ⟨E2, d2, Bs, Bt, hBs, hsc0, hBt, htc0, fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inl ?_)⟩
        exact views G hG o env sregs tregs hfs hts htt
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2
  | EndJmp i =>
    cases sv with
    | VJmp sj =>
      cases tv with
      | VJmp tj =>
        simp only at h2
        have h3 := pair_ok h2
        obtain ⟨e3, d3⟩ := next_ok_ext h3 d2 hvs2 hvt2 hfv2
        refine ⟨vg_extends_trans E2 e3, d3, Bs, Bt, hBs, hsc0, hBt, htc0,
          fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inr ?_)⟩
        obtain ⟨hes, het⟩ := views G (vg_extends_trans e3 hG) o env sregs tregs hfs hts htt
        refine ⟨⟨_, hes⟩, fun s hs => ?_⟩
        rw [edgeTaken_unique hs hes]
        exact ⟨tj, i, vg2, qg, het, h3, E2, d2, vg_extends_refl _⟩
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2
  | EndJnz sw i1 i2 =>
    cases sv with
    | VJnz cs s1 s2 =>
      cases tv with
      | VJnz ct t1 t2 =>
        simp only at h2
        have hcs := (hsj cs s1 s2 rfl).elim (fun h => Or.inl (extends_valid e2 h)) Or.inr
        have hct := htj ct t1 t2 rfl
        cases sw with
        | false =>
          simp only [Bool.not_false, ↓reduceIte] at h2
          obtain ⟨q21, hq21, h3⟩ := bind_eq_ok h2
          obtain ⟨t21, vg5⟩ := q21
          try simp only [uncurry_apply_pair] at h3
          obtain ⟨q24, hq24, h4⟩ := bind_eq_ok h3
          obtain ⟨t24, vg6⟩ := q24
          try simp only [uncurry_apply_pair] at h4
          cases t24 with
          | false => simp only [Bool.false_eq_true, ↓reduceIte] at h4; cases ok_inj' h4
          | true =>
          simp only [↓reduceIte] at h4
          cases t21 with
          | false => simp only [Bool.false_eq_true, ↓reduceIte] at hq24; cases ok_inj' hq24
          | true =>
          simp only [↓reduceIte] at hq24
          have h5 := pair_ok hq24
          have h6 := pair_ok h4
          obtain ⟨e5, d5⟩ := eq_under_ext hq21 d2
          obtain ⟨-, -, vcs, vct, heq⟩ := eq_under_sound hq21 d2
          obtain ⟨e6, d6⟩ := next_ok_ext h5 d5 (vidsOK_extends e5 hvs2) (vidsOK_extends e5 hvt2)
            (fun fb hm => extends_valid e5 (hfv2 fb hm))
          obtain ⟨e7, d7⟩ := next_ok_ext h6 d6 (vidsOK_extends (vg_extends_trans e5 e6) hvs2)
            (vidsOK_extends (vg_extends_trans e5 e6) hvt2) (fun fb hm => extends_valid (vg_extends_trans e5 e6) (hfv2 fb hm))
          refine ⟨vg_extends_trans E2 (vg_extends_trans e5 (vg_extends_trans e6 e7)), d7, Bs, Bt, hBs, hsc0, hBt, htc0,
            fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inr ?_)⟩
          have E5 : vg_extends vg2 G := vg_extends_trans e5 (vg_extends_trans e6 (vg_extends_trans e7 hG))
          obtain ⟨⟨_, c, hBsT, hcv⟩, ⟨_, c', hBtT, hct'⟩⟩ := views G E5 o env sregs tregs hfs hts htt
          refine ⟨⟨_, by rw [hBsT]; rfl⟩, fun s hs => ?_⟩
          have hcond : atomVal o sregs .W c = atomVal o tregs .W c' := by
            rw [← hcv (extends_valid E5 vcs), ← hct' (extends_valid E5 vct), extends_evI E5 env vcs,
              extends_evI E5 env vct]
            exact heq G env (vg_extends_trans e6 (vg_extends_trans e7 hG)) hfs
          rw [hBsT] at hs
          simp only [EdgeTaken] at hs
          by_cases hc0 : atomVal o sregs .W c ≠ 0
          · rw [ite_eq_left hc0] at hs
            subst hs
            refine ⟨t1, i1, vg5, vg6, ?_, h5, vg_extends_trans E2 e5, d5, vg_extends_trans e7 (vg_extends_refl _)⟩
            rw [hBtT]; simp only [EdgeTaken]; rw [ite_eq_left (by rw [← hcond]; exact hc0)]
          · rw [ite_eq_right hc0] at hs
            subst hs
            refine ⟨t2, i2, vg6, qg, ?_, h6, vg_extends_trans E2 (vg_extends_trans e5 e6), d6, vg_extends_refl _⟩
            rw [hBtT]; simp only [EdgeTaken]; rw [ite_eq_right (by rw [← hcond]; exact hc0)]
        | true =>
          simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h2
          obtain ⟨q9, hq9, h3⟩ := bind_eq_ok h2
          obtain ⟨ns, vg9⟩ := q9
          try simp only [uncurry_apply_pair] at h3
          obtain ⟨q10, hq10, h4⟩ := bind_eq_ok h3
          obtain ⟨nt, vg10⟩ := q10
          try simp only [uncurry_apply_pair] at h4
          obtain ⟨q11, hq11, h5⟩ := bind_eq_ok h4
          obtain ⟨t33, vg11⟩ := q11
          try simp only [uncurry_apply_pair] at h5
          obtain ⟨q12, hq12, h6⟩ := bind_eq_ok h5
          obtain ⟨t36, vg12⟩ := q12
          try simp only [uncurry_apply_pair] at h6
          obtain ⟨q14, hq14, h7⟩ := bind_eq_ok h6
          obtain ⟨t39, vg14⟩ := q14
          try simp only [uncurry_apply_pair] at h7
          cases t39 with
          | false => simp only [Bool.false_eq_true, ↓reduceIte] at h7; cases ok_inj' h7
          | true =>
          simp only [↓reduceIte] at h7
          cases t36 with
          | false => simp only [Bool.false_eq_true, ↓reduceIte] at hq14; cases ok_inj' hq14
          | true =>
          simp only [↓reduceIte] at hq14
          have hn1 := pair_ok hq14
          have hn2 := pair_ok h7
          obtain ⟨e9, d9, hns, hns'⟩ := cmp_zero_sound hq9 d2 hcs
          dsimp only at e9 d9 hns hns'
          obtain ⟨e10, d10, hnt, hnt'⟩ := cmp_zero_sound hq10 d9
            (hct.elim (fun h => Or.inl (extends_valid e9 h)) Or.inr)
          dsimp only at e10 d10 hnt hnt'
          obtain ⟨e11, d11⟩ := eq_under_ext hq11 d10
          dsimp only at e11 d11
          -- one of the two comparisons holds
          have hcmp : vg_extends vg10 vg12 ∧ ValGraphDAG vg12 ∧ ∀ G, vg_extends vg12 G → ∀ env, FactsHold G env fs.val →
              Valid vg2 cs ∧ Valid vg2 ct ∧
              (evI vg2 env ct = b2v (decide (maskC .W (evI vg2 env cs) = 0)) ∨
               evI vg2 env cs = b2v (decide (maskC .W (evI vg2 env ct) = 0))) := by
            cases t33 with
            | true =>
              simp only [↓reduceIte] at hq12
              cases ok_inj' hq12
              obtain ⟨-, -, vns, vct, heq⟩ := eq_under_sound hq11 d10
              have vcs : Valid vg2 cs := by
                by_contra hc
                have := hns' hc
                have := vns.1
                omega
              refine ⟨e11, d11, fun G hG env hfs => ⟨vcs, ?_, Or.inl ?_⟩⟩
              · by_contra hc
                rcases hct with h' | h'
                · exact hc h'
                · have := vct.1; omega
              · have := heq G env hG hfs
                rw [extends_evI e10 env (hns vcs).1, (hns vcs).2 env] at this
                have vct2 : Valid vg2 ct := by
                  rcases hct with h' | h'
                  · exact h'
                  · have := vct.1; omega
                rw [extends_evI (vg_extends_trans e9 e10) env vct2] at this
                exact this.symm
            | false =>
              simp only [Bool.false_eq_true, ↓reduceIte] at hq12
              have hq12' := pair_ok hq12
              obtain ⟨e12, d12⟩ := eq_under_ext hq12' d11
              obtain ⟨-, -, vcs, vnt, heq⟩ := eq_under_sound hq12' d11
              have vct : Valid vg9 ct := by
                by_contra hc
                have := hnt' hc
                have := vnt.1
                omega
              have vct2 : Valid vg2 ct := by
                rcases hct with h' | h'
                · exact h'
                · have := vct.1; omega
              have vcs2 : Valid vg2 cs := by
                rcases hcs with h' | h'
                · exact h'
                · have := vcs.1; omega
              refine ⟨vg_extends_trans e11 e12, d12, fun G hG env hfs => ⟨vcs2, vct2, Or.inr ?_⟩⟩
              have := heq G env hG hfs
              rw [extends_evI (vg_extends_trans e9 (vg_extends_trans e10 e11)) env vcs2, extends_evI e11 env (hnt vct).1,
                (hnt vct).2 env, extends_evI e9 env vct2] at this
              exact this
          obtain ⟨e12, d12, hcmp'⟩ := hcmp
          have E12 : vg_extends vg2 vg12 := vg_extends_trans e9 (vg_extends_trans e10 e12)
          obtain ⟨e13, d13⟩ := next_ok_ext hn1 d12 (vidsOK_extends E12 hvs2) (vidsOK_extends E12 hvt2)
            (fun fb hm => extends_valid E12 (hfv2 fb hm))
          obtain ⟨e14, d14⟩ := next_ok_ext hn2 d13 (vidsOK_extends (vg_extends_trans E12 e13) hvs2)
            (vidsOK_extends (vg_extends_trans E12 e13) hvt2) (fun fb hm => extends_valid (vg_extends_trans E12 e13) (hfv2 fb hm))
          refine ⟨vg_extends_trans E2 (vg_extends_trans E12 (vg_extends_trans e13 e14)), d14, Bs, Bt, hBs, hsc0, hBt, htc0,
            fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inr ?_)⟩
          have G12 : vg_extends vg12 G := vg_extends_trans e13 (vg_extends_trans e14 hG)
          have E5 : vg_extends vg2 G := vg_extends_trans E12 G12
          obtain ⟨⟨_, c, hBsT, hcv⟩, ⟨_, c', hBtT, hct'⟩⟩ := views G E5 o env sregs tregs hfs hts htt
          refine ⟨⟨_, by rw [hBsT]; rfl⟩, fun s hs => ?_⟩
          obtain ⟨vcs, vct, hor⟩ := hcmp' G G12 env hfs
          have hsv := hcv (extends_valid E5 vcs)
          have htv := hct' (extends_valid E5 vct)
          rw [extends_evI E5 env vcs] at hsv
          rw [extends_evI E5 env vct] at htv
          have hiff : atomVal o sregs .W c ≠ 0 ↔ atomVal o tregs .W c' = 0 := by
            rcases hor with h' | h'
            · rw [htv, hsv, hmW] at h'
              rw [h']
              by_cases hz : atomVal o sregs .W c = 0 <;> simp [hz, b2v]
            · rw [hsv, htv, hmW] at h'
              rw [h']
              by_cases hz : atomVal o tregs .W c' = 0 <;> simp [hz, b2v]
          rw [hBsT] at hs
          simp only [EdgeTaken] at hs
          by_cases hc0 : atomVal o sregs .W c ≠ 0
          · rw [ite_eq_left hc0] at hs
            subst hs
            refine ⟨t2, i1, vg12, vg14, ?_, hn1, vg_extends_trans E2 E12, d12, vg_extends_trans e14 (vg_extends_refl _)⟩
            rw [hBtT]; simp only [EdgeTaken]; rw [ite_eq_right (by simpa using hiff.1 hc0)]
          · rw [ite_eq_right hc0] at hs
            subst hs
            refine ⟨t1, i2, vg14, qg, ?_, hn2, vg_extends_trans E2 (vg_extends_trans E12 e13), d13, vg_extends_refl _⟩
            rw [hBtT]; simp only [EdgeTaken]
            rw [ite_eq_left (fun hz => hc0 (hiff.2 hz))]
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2
  | EndSrcBranch i1 i2 =>
    cases sv with
    | VJnz cs s1 s2 =>
      cases tv with
      | VJmp tj =>
        simp only at h2
        obtain ⟨q47, hq47, h3⟩ := bind_eq_ok h2
        obtain ⟨t47, vg17⟩ := q47
        try simp only [uncurry_apply_pair] at h3
        cases t47 with
        | false => simp only [Bool.false_eq_true, ↓reduceIte] at h3; cases ok_inj' h3
        | true =>
        simp only [↓reduceIte] at h3
        have h4 := pair_ok h3
        obtain ⟨e17, d17⟩ := next_ok_ext hq47 d2 hvs2 hvt2 hfv2
        obtain ⟨e18, d18⟩ := next_ok_ext h4 d17 (vidsOK_extends e17 hvs2) (vidsOK_extends e17 hvt2)
          (fun fb hm => extends_valid e17 (hfv2 fb hm))
        refine ⟨vg_extends_trans E2 (vg_extends_trans e17 e18), d18, Bs, Bt, hBs, hsc0, hBt, htc0,
          fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inr ?_)⟩
        obtain ⟨⟨_, c, hBsT, -⟩, het⟩ := views G (vg_extends_trans e17 (vg_extends_trans e18 hG)) o env sregs tregs hfs hts htt
        refine ⟨⟨_, by rw [hBsT]; rfl⟩, fun s hs => ?_⟩
        rw [hBsT] at hs
        simp only [EdgeTaken] at hs
        split at hs
        · subst hs
          exact ⟨tj, i1, vg2, vg17, het, hq47, E2, d2, e18⟩
        · subst hs
          exact ⟨tj, i2, vg17, qg, het, h4, vg_extends_trans E2 e17, d17, vg_extends_refl _⟩
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2
  | EndTgtBranch i1 i2 =>
    cases sv with
    | VJmp sj =>
      cases tv with
      | VJnz ct t1 t2 =>
        simp only at h2
        obtain ⟨q54, hq54, h3⟩ := bind_eq_ok h2
        obtain ⟨t54, vg19⟩ := q54
        try simp only [uncurry_apply_pair] at h3
        cases t54 with
        | false => simp only [Bool.false_eq_true, ↓reduceIte] at h3; cases ok_inj' h3
        | true =>
        simp only [↓reduceIte] at h3
        have h4 := pair_ok h3
        obtain ⟨e19, d19⟩ := next_ok_ext hq54 d2 hvs2 hvt2 hfv2
        obtain ⟨e20, d20⟩ := next_ok_ext h4 d19 (vidsOK_extends e19 hvs2) (vidsOK_extends e19 hvt2)
          (fun fb hm => extends_valid e19 (hfv2 fb hm))
        refine ⟨vg_extends_trans E2 (vg_extends_trans e19 e20), d20, Bs, Bt, hBs, hsc0, hBt, htc0,
          fun G hG W o env sregs tregs hfs hts htt => Or.inr (Or.inr ?_)⟩
        obtain ⟨hes, ⟨_, c', hBtT, -⟩⟩ := views G (vg_extends_trans e19 (vg_extends_trans e20 hG)) o env sregs tregs hfs hts htt
        refine ⟨⟨_, hes⟩, fun s hs => ?_⟩
        rw [edgeTaken_unique hs hes]
        by_cases hc0 : atomVal o tregs .W c' ≠ 0
        · refine ⟨t1, i1, vg2, vg19, ?_, hq54, E2, d2, e20⟩
          rw [hBtT]; simp only [EdgeTaken]; rw [ite_eq_left hc0]
        · refine ⟨t2, i2, vg19, qg, ?_, h4, vg_extends_trans E2 e19, d19, vg_extends_refl _⟩
          rw [hBtT]; simp only [EdgeTaken]; rw [ite_eq_right hc0]
      | _ => simp only at h2; cases ok_inj' h2
    | _ => simp only at h2; cases ok_inj' h2

/-! ## Empty blocks the source may pass through -/

/-- A block with no phi, only pure non-trapping instructions, ending with `jmp n`. -/
def TrivBlk (B : Block) (n : Std.I32) : Prop :=
  B.phis.val = [] ∧ (∀ inst ∈ B.insts.val, NoWorld inst ∧ leafB inst = false) ∧ B.term = .Jmp n

/-- `b` is reached from `b0` through trivial blocks. -/
inductive TrivReach (f : Func) (b0 : Std.I32) : Std.I32 → Prop where
  | refl : TrivReach f b0 b0
  | step {b n : Std.I32} {B : Block} : TrivReach f b0 b → 0 ≤ b.val → f.blocks.val[b.val.toNat]? = some B →
      TrivBlk B n → TrivReach f b0 n

theorem is_trivial_sound {f : Func} {b : Std.I32} (h : is_trivial f b = ok true) :
    0 ≤ b.val ∧ ∃ B n, f.blocks.val[b.val.toNat]? = some B ∧ TrivBlk B n := by
  unfold is_trivial at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨hb0, hBl, hBv⟩ := arr_get_ok hB
  obtain ⟨np, hnp, h2⟩ := bind_eq_ok h1
  obtain ⟨hnp1, -⟩ := arr_length_ok hnp
  by_cases hp : np > 0#i32
  · rw [ite_eq_left hp] at h2; cases ok_inj' h2
  rw [ite_eq_right hp] at h2
  have hph : B.phis.val = [] := by
    apply List.eq_nil_of_length_eq_zero
    have : np.val ≤ 0 := by simpa [i32_lt_iff, gt_iff_lt] using hp
    omega
  obtain ⟨B2, hB2, h3⟩ := bind_eq_ok h2
  rw [hB] at hB2; cases ok_inj' hB2
  obtain ⟨n, hn, h3⟩ := bind_eq_ok h3
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h4⟩ := bind_eq_ok h3
  have key := scan_loop (fun i => is_trivial_loop0.body n B.insts i) B.insts.val.length
    (fun k => ∀ hk : k < B.insts.val.length, NoWorld B.insts.val[k] ∧ leafB B.insts.val[k] = false)
    (fun _ r => r = false) (fun _ => True)
    (by
      intro i c hi hc
      unfold is_trivial_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < B.insts.val.length := by simpa [i32_lt_iff, hn1] using hlt
        obtain ⟨inst, hinst, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hil, hiv⟩ := arr_get_ok hinst
        obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
        left
        refine ⟨hlt', hn2, ?_⟩
        have hgood : sres = .inr () → NoWorld inst ∧ leafB inst = false := by
          intro hr
          subst hr
          cases inst with
          | Par _ _ _ => exact ⟨trivial, rfl⟩
          | Un _ _ _ _ => exact ⟨trivial, rfl⟩
          | Bin _ _ op _ _ =>
            simp only [is_trapping_binop_spec, bind_ok] at hsres
            cases htr : trapOp op
            · exact ⟨trivial, htr⟩
            · rw [htr] at hsres; simp at hsres
          | _ => simp at hsres
        cases sres with
        | inl r =>
          left
          simp only at hc
          refine ⟨r, (ok_inj' hc).symm, ?_⟩
          cases inst with
          | Bin _ _ op _ _ =>
            simp only [is_trapping_binop_spec, bind_ok] at hsres
            split at hsres
            · cases ok_inj' hsres; rfl
            · cases ok_inj' hsres
          | Par _ _ _ => cases ok_inj' hsres
          | Un _ _ _ _ => cases ok_inj' hsres
          | _ => cases ok_inj' hsres; rfl
        | inr u =>
          right
          simp only at hc
          refine ⟨fun _ => ?_, (ok_inj' hc).symm⟩
          rw [hiv]; exact hgood rfl
      · rename_i hge
        right
        exact ⟨by simpa [i32_lt_iff, hn1] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 s hs (by simp)
  cases s with
  | inl r =>
    obtain ⟨_, -, -, hr, -⟩ := hk
    simp only at h4
    rw [hr] at h4; cases ok_inj' h4
  | inr g =>
    simp only at h4
    obtain ⟨B3, hB3, h5⟩ := bind_eq_ok h4
    rw [hB] at hB3; cases ok_inj' hB3
    generalize hT : B.term = T at h5
    cases T with
    | Jmp n =>
      refine ⟨hb0, B, n, by rw [List.getElem?_eq_getElem hBl, hBv], hph, fun inst hm => ?_, hT⟩
      obtain ⟨k, hk', rfl⟩ := List.getElem_of_mem hm
      exact hk.2 k (by simp) hk' hk'
    | _ => simp only at h5; cases ok_inj' h5

theorem resolve_trivial_sound {f : Func} {b0 r : Std.I32} (h : resolve_trivial f b0 = ok r) :
    TrivReach f b0 r := by
  unfold resolve_trivial at h
  obtain ⟨nb, hnb, h1⟩ := bind_eq_ok h
  obtain ⟨q, hq, h2⟩ := bind_eq_ok h1
  obtain ⟨st, b1⟩ := q
  have hr : b1 = r := ok_inj' h2
  subst hr
  unfold resolve_trivial_loop0 at hq
  have key := loop_ok_inv (fun (x : Std.I32 × Std.I32) =>
      match x with | (steps, b) => resolve_trivial_loop0.body nb f steps b)
    (fun x => TrivReach f b0 x.2) (fun y => TrivReach f b0 y.2)
    ?_ _ _ hq TrivReach.refl
  · exact key
  rintro ⟨st, b⟩ c hreach hc
  try dsimp only at hreach hc
  unfold resolve_trivial_loop0.body at hc
  obtain ⟨t2, ht2, hc1⟩ := bind_eq_ok hc
  cases t2 with
  | false => simp only [Bool.false_eq_true, ↓reduceIte] at hc1; rw [← ok_inj' hc1]; exact hreach
  | true =>
    simp only [↓reduceIte] at hc1
    have htriv : is_trivial f b = ok true := by
      split at ht2
      · exact bind_id_ok ht2
      · cases ok_inj' ht2
    obtain ⟨hb0, B, n, hB, hT⟩ := is_trivial_sound htriv
    obtain ⟨B2, hB2, hc2⟩ := bind_eq_ok hc1
    obtain ⟨_, hB2l, hB2v⟩ := arr_get_ok hB2
    rw [List.getElem?_eq_getElem hB2l, hB2v] at hB
    cases hB
    rw [hT.2.2] at hc2
    simp only [bind_ok] at hc2
    rw [← ok_inj' hc2]
    exact TrivReach.step hreach hb0 (by rw [List.getElem?_eq_getElem hB2l, hB2v]) hT

theorem src_join_sound {f : Func} {b r : Std.I32} (h : src_join f b = ok r) (hr : 0 ≤ r.val) :
    ∃ B c s1 s2, f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ b.val ∧ B.term = .Jnz c s1 s2 ∧
      TrivReach f s1 r ∧ TrivReach f s2 r := by
  unfold src_join at h
  obtain ⟨B, hB, h1⟩ := bind_eq_ok h
  obtain ⟨hb0, hBl, hBv⟩ := arr_get_ok hB
  generalize hT : B.term = T at h1
  cases T with
  | Jnz c s1 s2 =>
    simp only at h1
    obtain ⟨r1, hr1, h2⟩ := bind_eq_ok h1
    obtain ⟨r2, hr2, h3⟩ := bind_eq_ok h2
    by_cases he : r1 = r2
    · rw [ite_eq_left he] at h3
      cases ok_inj' h3
      subst he
      exact ⟨B, c, s1, s2, by rw [List.getElem?_eq_getElem hBl, hBv], hb0, hT,
        resolve_trivial_sound hr1, resolve_trivial_sound hr2⟩
    · rw [ite_eq_right he] at h3; cases ok_inj' h3; simp at hr
  | _ => simp only at h1; cases ok_inj' h1; simp at hr

end PionProofs.QbeTvP
