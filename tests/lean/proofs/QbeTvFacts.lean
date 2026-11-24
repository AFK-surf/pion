/-
The certificate checks of `tools/qbe_tv/src/validate.pion` the end-to-end proof
(`QbeTvProofs`) builds on:

1. `wf_code_sound`, `build_info_sound`: the entry block has no phi, every
   jump target is a block other than the entry, `reach[0]` and `reach` is closed
   under the CFG edges;
2. `apply_facts_sound`, `eq_under_sound`: substituting branch facts keeps the
   value of a node under every environment where the facts hold;
3. `edge_facts_sound`, `check_facts_sound`: the facts of a block hold whenever
   the block is entered;
4. `check_avail_sound`: the initialisation certificate.
-/
import PionProofs.QbeTvCanon
open Aeneas Aeneas.Std Result Pion

set_option maxRecDepth 100000
set_option maxHeartbeats 4000000

namespace PionProofs.QbeTvP

open qbe_tv

/-! ## Arithmetic and list helpers -/

theorem i32_succ_val {i n : Std.I32} (h : i.val < n.val) : (Pion.I32.add i 1#i32).val = i.val + 1 := by
  have h1 := n.hmax
  have h2 := i.hmin
  simp only [IScalarTy.numBits] at h1 h2
  exact i32_add_val i 1#i32 (by simp; omega) (by simp; omega)

theorem i32_succ_val' {i : Std.I32} {m : Nat} (h : i.val < m) (hm : m ≤ 2147483647) :
    (Pion.I32.add i 1#i32).val = i.val + 1 := by
  have h2 := i.hmin
  simp only [IScalarTy.numBits] at h2
  exact i32_add_val i 1#i32 (by simp; omega) (by simp; omega)

theorem i32_val_le (x : Std.I32) : x.val ≤ 2147483647 := by
  have := x.hmax; simp only [IScalarTy.numBits] at this; omega

theorem i32_beq_iff (a b : Std.I32) : (a == b) = true ↔ a = b := beq_iff_eq

theorem bool_beq_iff (a b : Bool) : (a == b) = true ↔ a = b := beq_iff_eq

theorem i32_eq_of_val {a b : Std.I32} (h : a.val = b.val) : a = b := i32_ext h

theorem i32_ne_iff {a b : Std.I32} : a ≠ b ↔ a.val ≠ b.val :=
  ⟨fun h e => h (i32_ext e), fun h e => h (by rw [e])⟩

theorem getElem?_toNat {α : Type} {l : List α} {i : Std.I32} (_h0 : 0 ≤ i.val)
    (h : i.val.toNat < l.length) : l[i.val.toNat]? = some (l[i.val.toNat]'h) :=
  List.getElem?_eq_getElem h

/-- A loop over `[i0, n)` that stops early with `inl` or finishes with `inr`: the
generic shape of every `for` / `while` scan of `validate.pion`. -/
theorem scan_loop {β γ : Type} (body : Std.I32 → Result (ControlFlow Std.I32 (Sum β γ)))
    (n : Nat) (Good : Nat → Prop) (Early : Std.I32 → β → Prop) (Fin : γ → Prop)
    (hb : ∀ i c, 0 ≤ i.val → body i = ok c →
      (i.val < n ∧ n ≤ 2147483647 ∧ ((∃ r, c = .done (.inl r) ∧ Early i r) ∨
        (Good i.val.toNat ∧ c = .cont (Pion.I32.add i 1#i32))))
      ∨ (n ≤ i.val ∧ ∃ g, c = .done (.inr g) ∧ Fin g)) :
    ∀ i0 r, loop body i0 = ok r → 0 ≤ i0.val →
      match r with
      | .inl b => ∃ i : Std.I32, i0.val ≤ i.val ∧ i.val < n ∧ Early i b ∧
          ∀ k, i0.val.toNat ≤ k → k < i.val.toNat → Good k
      | .inr g => Fin g ∧ ∀ k, i0.val.toNat ≤ k → k < n → Good k := by
  intro i0 r h hi0
  refine loop_ok_inv body
    (fun i : Std.I32 => 0 ≤ i.val ∧ i0.val ≤ i.val ∧ ∀ k, i0.val.toNat ≤ k → k < i.val.toNat → Good k)
    (fun r => match r with
      | .inl b => ∃ i : Std.I32, i0.val ≤ i.val ∧ i.val < n ∧ Early i b ∧
          ∀ k, i0.val.toNat ≤ k → k < i.val.toNat → Good k
      | .inr g => Fin g ∧ ∀ k, i0.val.toNat ≤ k → k < n → Good k) ?_ i0 r h
      ⟨hi0, le_refl _, fun k h1 h2 => by omega⟩
  intro i c ⟨hi, hii, hg⟩ hc
  rcases hb i c hi hc with ⟨hlt, hn, ⟨r, rfl, hr⟩ | ⟨hgood, rfl⟩⟩ | ⟨hge, g, rfl, hgf⟩
  · exact ⟨i, hii, hlt, hr, hg⟩
  · have hs := i32_succ_val' hlt hn
    refine ⟨by omega, by omega, fun k h1 h2 => ?_⟩
    by_cases hk : k < i.val.toNat
    · exact hg k h1 hk
    · have : k = i.val.toNat := by omega
      rw [this]; exact hgood
  · refine ⟨hgf, fun k h1 h2 => hg k h1 (by omega)⟩

/-! ## Small functions -/

/-- The successors of a terminator. -/
def termSuccs : Term → List Std.I32
  | .Jmp s => [s]
  | .Jnz _ s1 s2 => [s1, s2]
  | _ => []

theorem term_nsucc_spec (t : Term) : term_nsucc t = ok ⟨BitVec.ofNat 32 (termSuccs t).length⟩ := by
  cases t <;> rfl

theorem term_succ_spec (t : Term) (k : Std.I32) (hk : 0 ≤ k.val) (hk2 : k.val < (termSuccs t).length) :
    term_succ t k = ok ((termSuccs t)[k.val.toNat]'(by omega)) := by
  cases t with
  | Jmp s =>
    simp only [termSuccs, List.length_singleton] at hk2
    have : k = 0#i32 := i32_ext (by simp; omega)
    subst this
    simp [term_succ, termSuccs]
  | Jnz a s1 s2 =>
    simp only [termSuccs, List.length_cons, List.length_nil] at hk2
    by_cases h0 : k.val = 0
    · have : k = 0#i32 := i32_ext (by simp; omega)
      subst this
      simp [term_succ, termSuccs]
    · have h1 : k.val = 1 := by omega
      have : k = 1#i32 := i32_ext (by simp; omega)
      subst this
      have hne : (1#i32 : Std.I32) ≠ 0#i32 := by decide
      simp [term_succ, termSuccs, hne]
  | Ret _ _ _ => simp [termSuccs] at hk2; omega
  | Hlt => simp [termSuccs] at hk2; omega

theorem termSuccs_len (t : Term) : (termSuccs t).length ≤ 2 := by
  cases t <;> simp [termSuccs]

theorem nsucc_val (t : Term) : (⟨BitVec.ofNat 32 (termSuccs t).length⟩ : Std.I32).val = (termSuccs t).length := by
  cases t <;> simp only [termSuccs, List.length_cons, List.length_nil] <;> decide

/-- `is_edge f p s`: `s` is a successor of block `p`. -/
theorem is_edge_true {f : Func} {p s : Std.I32} (h : is_edge f p s = ok true) :
    ∃ B, 0 ≤ p.val ∧ f.blocks.val[p.val.toNat]? = some B ∧ s ∈ termSuccs B.term := by
  unfold is_edge at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨hp0, hpl, hpB⟩ := arr_get_ok hB
  simp only [term_nsucc_spec, bind_ok] at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun k => is_edge_loop0.body ⟨BitVec.ofNat 32 (termSuccs B.term).length⟩ B.term s k)
    (termSuccs B.term).length
    (fun _ => True) (fun _ b => b = true → s ∈ termSuccs B.term) (fun _ => True)
    (by
      intro i c hi hc
      unfold is_edge_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < (termSuccs B.term).length := by
          have := nsucc_val B.term; simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := termSuccs_len B.term; omega, ?_⟩
        rw [term_succ_spec _ _ hi hlt'] at hc
        simp only [bind_ok] at hc
        split at hc
        · rename_i he
          left
          refine ⟨true, (ok_inj' hc).symm, fun _ => ?_⟩
          rw [← he]
          exact List.getElem_mem _
        · right
          exact ⟨trivial, (ok_inj' hc).symm⟩
      · rename_i hge
        right
        have := nsucc_val B.term
        simp only [i32_lt_iff] at hge
        exact ⟨by omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b =>
    try simp only at h
    have hb : b = true := ok_inj' h
    obtain ⟨_, _, _, hk, _⟩ := hk
    exact ⟨B, hp0, by rw [getElem?_toNat hp0 hpl, hpB], hk hb⟩
  | inr g => simp at h

/-- `is_edge f p s = false`: `s` is no successor of block `p`. -/
theorem is_edge_false {f : Func} {p s : Std.I32} (h : is_edge f p s = ok false) :
    ∀ B, 0 ≤ p.val → f.blocks.val[p.val.toNat]? = some B → s ∉ termSuccs B.term := by
  intro B' hp0' hB'
  unfold is_edge at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨hp0, hpl, hpB⟩ := arr_get_ok hB
  have hBB : B' = B := by rw [List.getElem?_eq_getElem hpl, hpB] at hB'; cases hB'; rfl
  subst hBB
  simp only [term_nsucc_spec, bind_ok] at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun k => is_edge_loop0.body ⟨BitVec.ofNat 32 (termSuccs B'.term).length⟩ B'.term s k)
    (termSuccs B'.term).length
    (fun k => ∀ hk : k < (termSuccs B'.term).length, (termSuccs B'.term)[k] ≠ s)
    (fun _ b => b = true) (fun _ => True)
    (by
      intro i c hi hc
      unfold is_edge_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < (termSuccs B'.term).length := by
          have := nsucc_val B'.term; simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := termSuccs_len B'.term; omega, ?_⟩
        rw [term_succ_spec _ _ hi hlt'] at hc
        simp only [bind_ok] at hc
        split at hc
        · left
          exact ⟨true, (ok_inj' hc).symm, rfl⟩
        · rename_i hne
          right
          exact ⟨fun hk => hne, (ok_inj' hc).symm⟩
      · rename_i hge
        right
        have := nsucc_val B'.term
        simp only [i32_lt_iff] at hge
        exact ⟨by omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b =>
    obtain ⟨_, _, _, hb, _⟩ := hk
    simp only at h
    subst hb
    cases ok_inj' h
  | inr g =>
    intro hm
    obtain ⟨k, hkl, hks⟩ := List.getElem_of_mem hm
    exact hk.2 k (by simp) hkl hkl hks

/-- The temp an instruction defines (`-1` for none). -/
def instDst : Inst → Std.I32
  | .Par d _ _ => d
  | .Un d _ _ _ => d
  | .Bin d _ _ _ _ => d
  | .Load d _ _ _ _ => d
  | .Store _ _ _ => (-1)#i32
  | .Call d _ h _ _ => if h then d else (-1)#i32
  | .Alloc d _ _ => d

theorem inst_dst_spec (inst : Inst) : inst_dst inst = ok (instDst inst) := by
  cases inst <;> rfl

/-- `contains_int xs x`. -/
theorem contains_int_spec {xs : Pion.Array Std.I32} {x : Std.I32} {b : Bool}
    (h : contains_int xs x = ok b) : b = true ↔ x ∈ xs.val := by
  unfold contains_int at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun i => contains_int_loop0.body xs x i) xs.val.length
    (fun k => ∀ hk : k < xs.val.length, xs.val[k] ≠ x) (fun _ b => b = true ∧ x ∈ xs.val) (fun _ => True)
    (by
      intro i c hi hc
      unfold contains_int_loop0.body at hc
      obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
      obtain ⟨ht1, ht2⟩ := arr_length_ok ht
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, ht1] at hlt
        obtain ⟨y, hy, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hyl, hyv⟩ := arr_get_ok hy
        left
        refine ⟨hlt, ht2, ?_⟩
        split at hc
        · rename_i he
          left
          exact ⟨true, (ok_inj' hc).symm, rfl, by rw [← he, ← hyv]; exact List.getElem_mem _⟩
        · rename_i he
          right
          exact ⟨fun hk => by rw [hyv]; exact he, (ok_inj' hc).symm⟩
      · rename_i hge
        simp only [i32_lt_iff, ht1, not_lt] at hge
        right
        exact ⟨hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b' =>
    have hb : b = b' := (ok_inj' h).symm
    subst hb
    simp only at hk
    obtain ⟨_, _, _, hk, _⟩ := hk
    exact ⟨fun _ => hk.2, fun _ => hk.1⟩
  | inr g =>
    have hb : b = false := (ok_inj' h).symm
    subst hb
    simp only at hk
    refine ⟨fun e => (by cases e), fun hm => ?_⟩
    obtain ⟨k, hkl, hkx⟩ := List.getElem_of_mem hm
    exact absurd hkx (hk.2 k (by simp) hkl hkl)

/-- `facts_of facts b`: facts of block `b` (the binary search only decides which ones are found). -/
theorem mem_facts_of {facts : Pion.Array Fact} {b : Std.I32} {out : Pion.Array Fact}
    (h : facts_of facts b = ok out) {fa : Fact} (hfa : fa ∈ out.val) : fa ∈ facts.val ∧ fa.blk = b := by
  unfold facts_of at h
  obtain ⟨n, -, h⟩ := bind_eq_ok h
  obtain ⟨q, -, h⟩ := bind_eq_ok h
  obtain ⟨lo1, hi1⟩ := q
  try simp only [uncurry_apply_pair] at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  obtain ⟨j1, o1⟩ := r
  try simp only [uncurry_apply_pair] at h
  cases ok_inj' h
  unfold facts_of_loop1 at hr
  refine loop_ok_inv (fun (p : Std.I32 × Pion.Array Fact) => facts_of_loop1.body n facts b p.1 p.2)
    (fun p => ∀ fa ∈ p.2.val, fa ∈ facts.val ∧ fa.blk = b)
    (fun p => ∀ fa ∈ p.2.val, fa ∈ facts.val ∧ fa.blk = b) ?_ _ _ hr
    (fun fa hfa => by simp at hfa) fa hfa
  rintro ⟨j, o⟩ c hinv hc
  simp only at hinv hc
  unfold facts_of_loop1.body at hc
  obtain ⟨t4, ht4, hc⟩ := bind_eq_ok hc
  split at hc
  · rename_i h4
    obtain ⟨fb, hfb, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    have hb : fb.blk = b := by
      split at ht4
      · obtain ⟨fb', hfb', ht4⟩ := bind_eq_ok ht4
        rw [hfb] at hfb'
        cases ok_inj' hfb'
        have := ok_inj' ht4
        subst this
        exact (i32_beq_iff _ _).1 h4
      · cases ok_inj' ht4
        cases h4
    obtain ⟨_, hfl, hfv⟩ := arr_get_ok hfb
    intro fc hfc
    simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hfc
    rcases hfc with hfc | rfl
    · exact hinv fc hfc
    · exact ⟨by rw [← hfv]; exact List.getElem_mem _, hb⟩
  · rw [← ok_inj' hc]
    exact hinv

/-- `fact_in fs vid zero`. -/
theorem fact_in_spec {fs : Pion.Array Fact} {vid : Std.I32} {zero b : Bool}
    (h : fact_in fs vid zero = ok b) : b = true ↔ ∃ fa ∈ fs.val, fa.vid = vid ∧ fa.zero = zero := by
  unfold fact_in at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun i => fact_in_loop0.body fs vid zero i) fs.val.length
    (fun k => ∀ hk : k < fs.val.length, ¬ (fs.val[k].vid = vid ∧ fs.val[k].zero = zero))
    (fun _ b => b = true ∧ ∃ fa ∈ fs.val, fa.vid = vid ∧ fa.zero = zero) (fun _ => True)
    (by
      intro i c hi hc
      unfold fact_in_loop0.body at hc
      obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
      obtain ⟨ht1, ht2⟩ := arr_length_ok ht
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, ht1] at hlt
        obtain ⟨fa, hfa, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hfl, hfv⟩ := arr_get_ok hfa
        left
        refine ⟨hlt, ht2, ?_⟩
        split at hc
        · rename_i he
          simp only [Bool.and_eq_true, beq_iff_eq] at he
          left
          exact ⟨true, (ok_inj' hc).symm, rfl, fa, by rw [← hfv]; exact List.getElem_mem _, he⟩
        · rename_i he
          simp only [Bool.and_eq_true, beq_iff_eq] at he
          right
          exact ⟨fun hk => by rw [hfv]; exact he, (ok_inj' hc).symm⟩
      · rename_i hge
        simp only [i32_lt_iff, ht1, not_lt] at hge
        right
        exact ⟨hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b' =>
    have hb : b = b' := (ok_inj' h).symm
    subst hb
    simp only at hk
    obtain ⟨_, _, _, hk, _⟩ := hk
    exact ⟨fun _ => hk.2, fun _ => hk.1⟩
  | inr g =>
    have hb : b = false := (ok_inj' h).symm
    subst hb
    simp only at hk
    refine ⟨fun e => (by cases e), fun ⟨fa, hm, hfa⟩ => ?_⟩
    obtain ⟨k, hkl, hkx⟩ := List.getElem_of_mem hm
    exact absurd (by rw [hkx]; exact hfa) (hk.2 k (by simp) hkl hkl)

/-- `fact_in_blk fs b vid zero`. -/
theorem fact_in_blk_spec {fs : Pion.Array Fact} {blk vid : Std.I32} {zero b : Bool}
    (h : fact_in_blk fs blk vid zero = ok b) :
    b = true → ∃ fa ∈ fs.val, fa.blk = blk ∧ fa.vid = vid ∧ fa.zero = zero := by
  intro hb
  unfold fact_in_blk at h
  obtain ⟨o, ho, h⟩ := bind_eq_ok h
  obtain ⟨t1, ht1, h⟩ := bind_eq_ok h
  have e := ok_inj' h
  subst e
  obtain ⟨fa, hfa, hv, hz⟩ := (fact_in_spec ht1).1 hb
  obtain ⟨hm, hbk⟩ := mem_facts_of ho hfa
  exact ⟨fa, hm, hbk, hv, hz⟩

/-- The first arm of `p` coming from `prev` (`phi_arm_index` / `phiArg`). -/
theorem phi_arm_index_spec {f : Func} {b k pred r : Std.I32} (h : phi_arm_index f b k pred = ok r) :
    ∃ B P, 0 ≤ b.val ∧ f.blocks.val[b.val.toNat]? = some B ∧ 0 ≤ k.val ∧
      B.phis.val[k.val.toNat]? = some P ∧
      ((0 ≤ r.val ∧ ∃ hr : r.val.toNat < P.arms.val.length, P.arms.val[r.val.toNat].pred = pred ∧
          ∀ j < r.val.toNat, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred ≠ pred) ∨
        (r.val = -1 ∧ ∀ j, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred ≠ pred)) := by
  unfold phi_arm_index at h
  obtain ⟨B, hB, h⟩ := bind_eq_ok h
  obtain ⟨hb0, hbl, hbv⟩ := arr_get_ok hB
  obtain ⟨P, hP, h⟩ := bind_eq_ok h
  obtain ⟨hk0, hkl, hkv⟩ := arr_get_ok hP
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  obtain ⟨hn1, hn2⟩ := arr_length_ok hn
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  refine ⟨B, P, hb0, by rw [getElem?_toNat hb0 hbl, hbv], hk0, by rw [getElem?_toNat hk0 hkl, hkv], ?_⟩
  have key := scan_loop (fun j => phi_arm_index_loop0.body n f b k pred j) P.arms.val.length
    (fun j => ∀ hj : j < P.arms.val.length, P.arms.val[j].pred ≠ pred)
    (fun j r => r = j ∧ 0 ≤ r.val ∧ ∃ hr : r.val.toNat < P.arms.val.length, P.arms.val[r.val.toNat].pred = pred)
    (fun _ => True)
    (by
      intro j c hj hc
      unfold phi_arm_index_loop0.body at hc
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, hn1] at hlt
        obtain ⟨B', hB', hc⟩ := bind_eq_ok hc
        rw [hB] at hB'; cases ok_inj' hB'
        obtain ⟨P', hP', hc⟩ := bind_eq_ok hc
        rw [hP] at hP'; cases ok_inj' hP'
        obtain ⟨a, ha, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hal, hav⟩ := arr_get_ok ha
        left
        refine ⟨hlt, hn2, ?_⟩
        split at hc
        · rename_i he
          left
          refine ⟨j, (ok_inj' hc).symm, rfl, hj, hal, ?_⟩
          rw [hav]; exact he
        · rename_i he
          right
          refine ⟨fun hj' => ?_, (ok_inj' hc).symm⟩
          rw [hav]; exact he
      · rename_i hge
        simp only [i32_lt_iff, hn1, not_lt] at hge
        right
        exact ⟨hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 s hs (by simp)
  cases s with
  | inl r' =>
    have := ok_inj' h
    subst this
    obtain ⟨i, _, _, ⟨rfl, h0, hr, hp⟩, hpre⟩ := hk
    left
    exact ⟨h0, hr, hp, fun j hj hj' => hpre j (by simp) hj hj'⟩
  | inr g =>
    have := ok_inj' h
    subst this
    right
    exact ⟨by decide, fun j hj => hk.2 j (by simp) hj hj⟩

/-! ## `wf_code` -/

/-- What the proof needs of a well-formed function (`wf_code f = 0`). -/
theorem bind_id_ok' {α : Type} {m : Result α} {r : α} (h : (do let x ← m; ok x) = ok r) : m = ok r := by
  obtain ⟨a, ha, e⟩ := bind_eq_ok h
  rw [ha, ok_inj' e]

/-- An instruction writing a temp names one in range (`dst_ok`). -/
def DstOK (nt : Std.I32) (inst : Inst) : Prop :=
  match inst with
  | .Store _ _ _ => True
  | .Call d _ h _ _ => h = true → 0 ≤ d.val ∧ d.val < nt.val
  | _ => 0 ≤ (instDst inst).val ∧ (instDst inst).val < nt.val

theorem temp_ok_true {nt t : Std.I32} (h : temp_ok nt t = ok true) : 0 ≤ t.val ∧ t.val < nt.val := by
  unfold temp_ok at h
  have := ok_inj' h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at this
  exact ⟨this.1, this.2⟩

theorem dst_ok_true {nt : Std.I32} {inst : Inst} (h : dst_ok nt inst = ok true) : DstOK nt inst := by
  unfold dst_ok at h
  cases inst with
  | Store _ _ _ => trivial
  | Call d c hh cal args =>
    simp only at h
    intro hht
    subst hht
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
    exact temp_ok_true (bind_id_ok' h)
  | Par d c k => exact temp_ok_true (bind_id_ok' h)
  | Un d c op a => exact temp_ok_true (bind_id_ok' h)
  | Bin d c op a b => exact temp_ok_true (bind_id_ok' h)
  | Load d c w sg a => exact temp_ok_true (bind_id_ok' h)
  | Alloc d al sz => exact temp_ok_true (bind_id_ok' h)

theorem dsts_ok_sound {f : Func} (h : dsts_ok f = ok true) :
    ∀ (b : Nat) (B : Block), f.blocks.val[b]? = some B → ∀ inst ∈ B.insts.val, DstOK f.ntemps inst := by
  unfold dsts_ok at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  have key := scan_loop (fun i => dsts_ok_loop0.body f.blocks f i) f.blocks.val.length
    (fun k => ∀ B : Block, f.blocks.val[k]? = some B → ∀ inst ∈ B.insts.val, DstOK f.ntemps inst)
    (fun _ b => b = false) (fun _ => True)
    (by
      intro i c hi hc
      unfold dsts_ok_loop0.body at hc
      obtain ⟨n, hn, hc⟩ := bind_eq_ok hc
      obtain ⟨hn1, hn2⟩ := arr_length_ok hn
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, hn1] at hlt
        obtain ⟨B, hB, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
        obtain ⟨s, hs, hc⟩ := bind_eq_ok hc
        left
        refine ⟨hlt, hn2, ?_⟩
        have key1 := scan_loop (fun j => dsts_ok_loop1.body B.insts f j) B.insts.val.length
          (fun k => ∀ hk : k < B.insts.val.length, DstOK f.ntemps B.insts.val[k])
          (fun _ b => b = false) (fun _ => True)
          (by
            intro j c hj hc
            unfold dsts_ok_loop1.body at hc
            obtain ⟨m, hm, hc⟩ := bind_eq_ok hc
            obtain ⟨hm1, hm2⟩ := arr_length_ok hm
            split at hc
            · rename_i hjlt
              simp only [i32_lt_iff, hm1] at hjlt
              obtain ⟨inst, hinst, hc⟩ := bind_eq_ok hc
              obtain ⟨_, hil, hiv⟩ := arr_get_ok hinst
              obtain ⟨t4, ht4, hc⟩ := bind_eq_ok hc
              left
              refine ⟨hjlt, hm2, ?_⟩
              split at hc
              · left; exact ⟨false, (ok_inj' hc).symm, rfl⟩
              · rename_i h4
                right
                refine ⟨fun hk => ?_, (ok_inj' hc).symm⟩
                rw [hiv]
                exact dst_ok_true (by rw [ht4]; simpa using h4)
            · rename_i hge
              right
              exact ⟨by simpa [i32_lt_iff, hm1] using hge, _, (ok_inj' hc).symm, trivial⟩)
        have hk1 := key1 0#i32 s hs (by simp)
        cases s with
        | inl b =>
          left
          obtain ⟨_, _, _, hb, _⟩ := hk1
          exact ⟨b, (ok_inj' hc).symm, hb⟩
        | inr g =>
          right
          refine ⟨fun B' hB' inst hm => ?_, (ok_inj' hc).symm⟩
          rw [List.getElem?_eq_getElem hBl, hBv] at hB'
          cases hB'
          obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hm
          exact hk1.2 k (by simp) hk hk
      · rename_i hge
        right
        exact ⟨by simpa [i32_lt_iff, hn1] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 r hr (by simp)
  cases r with
  | inl b =>
    obtain ⟨_, _, _, hb, _⟩ := hk
    subst hb
    simp only at h
    cases ok_inj' h
  | inr g =>
    intro b B hB inst hm
    have hbl : b < f.blocks.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hB; cases hB
    exact hk.2 b (by simp) hbl B hB inst hm

structure WFc (f : Func) : Prop where
  len_pos : 0 < f.blocks.val.length
  len_le : f.blocks.val.length ≤ 2147483647
  entry_nophi : ∀ B : Block, f.blocks.val[0]? = some B → B.phis.val = []
  succ_ok : ∀ (b : Nat) (B : Block), f.blocks.val[b]? = some B → ∀ s ∈ termSuccs B.term,
    0 < s.val ∧ s.val < f.blocks.val.length
  dsts : ∀ (b : Nat) (B : Block), f.blocks.val[b]? = some B → ∀ inst ∈ B.insts.val, DstOK f.ntemps inst

theorem loop_early_ne {α γ : Type} (body : α → Result (ControlFlow α (Sum Std.I32 γ)))
    (hb : ∀ x c, body x = ok c → ∀ r, c = .done (.inl r) → r ≠ 0#i32) :
    ∀ x r, loop body x = ok (.inl r) → r ≠ 0#i32 := by
  intro x r h
  exact loop_ok_inv body (fun _ => True)
    (fun s => match s with | .inl r => r ≠ 0#i32 | .inr _ => True)
    (by
      intro x c _ hc
      cases c with
      | cont x' => trivial
      | done y =>
        cases y with
        | inl r => exact hb x _ hc r rfl
        | inr _ => trivial) x _ h trivial

theorem wf_loop2_early (arms : Pion.Array PhiArm) (nb nt : Std.I32) :
    ∀ x r, wf_code_loop2 arms nb nt x = ok (.inl r) → r ≠ 0#i32 := by
  unfold wf_code_loop2
  apply loop_early_ne
  intro x c hc r hr
  subst hr
  simp only [wf_code_loop2.body] at hc
  obtain ⟨t, -, hc⟩ := bind_eq_ok hc
  split at hc
  · obtain ⟨arm, -, hc⟩ := bind_eq_ok hc
    split at hc
    · cases ok_inj' hc; decide
    · obtain ⟨t14, -, hc⟩ := bind_eq_ok hc
      split at hc
      · cases ok_inj' hc; decide
      · cases ok_inj' hc
  · cases ok_inj' hc

theorem wf_loop1_early (phis : Pion.Array Phi) (nt nb : Std.I32) :
    ∀ (x : Std.I32 × Pion.Array Std.I32) r, wf_code_loop1 phis nt nb x.1 x.2 = ok (.inl r) →
      r ≠ 0#i32 := by
  intro x r h
  unfold wf_code_loop1 at h
  refine loop_early_ne _ ?_ x r h
  rintro ⟨i, defs⟩ c hc r hr
  subst hr
  simp only [wf_code_loop1.body] at hc
  obtain ⟨t, -, hc⟩ := bind_eq_ok hc
  split at hc
  · obtain ⟨phi, -, hc⟩ := bind_eq_ok hc
    obtain ⟨t8, -, hc⟩ := bind_eq_ok hc
    split at hc
    · cases ok_inj' hc; decide
    · obtain ⟨t10, -, hc⟩ := bind_eq_ok hc
      obtain ⟨defs1, -, hc⟩ := bind_eq_ok hc
      obtain ⟨s, hs, hc⟩ := bind_eq_ok hc
      cases s with
      | inl r' =>
        try simp only at hc
        cases ok_inj' hc
        exact wf_loop2_early _ _ _ _ _ hs
      | inr _ =>
        try simp only at hc
        cases ok_inj' hc
  · cases ok_inj' hc

theorem wf_loop3_early (insts : Pion.Array Inst) (b : Std.I32) (f : Func) (nt : Std.I32) :
    ∀ (x : Std.I32 × Bool × Pion.Array Std.I32) r, wf_code_loop3 insts b f nt x.1 x.2.1 x.2.2 = ok (.inl r) →
      r ≠ 0#i32 := by
  intro x r h
  unfold wf_code_loop3 at h
  refine loop_early_ne _ ?_ x r h
  rintro ⟨i, seen, defs⟩ c hc r hr
  subst hr
  simp only [wf_code_loop3.body] at hc
  obtain ⟨t, -, hc⟩ := bind_eq_ok hc
  split at hc
  · obtain ⟨inst, -, hc⟩ := bind_eq_ok hc
    obtain ⟨s, hs, hc⟩ := bind_eq_ok hc
    cases s with
    | inl r' =>
      try simp only at hc
      cases ok_inj' hc
      split at hs
      · split at hs
        · cases ok_inj' hs; decide
        · split at hs
          · cases ok_inj' hs; decide
          · cases ok_inj' hs
      · cases ok_inj' hs
    | inr seen2 =>
      try simp only at hc
      obtain ⟨t18, -, hc⟩ := bind_eq_ok hc
      split at hc
      · cases ok_inj' hc; decide
      · obtain ⟨d, -, hc⟩ := bind_eq_ok hc
        obtain ⟨s1, hs1, hc⟩ := bind_eq_ok hc
        cases s1 with
        | inl r1 =>
          try simp only at hc
          cases ok_inj' hc
          split at hs1
          · obtain ⟨t20, -, hs1⟩ := bind_eq_ok hs1
            split at hs1
            · cases ok_inj' hs1; decide
            · obtain ⟨t22, -, hs1⟩ := bind_eq_ok hs1
              obtain ⟨d1, -, hs1⟩ := bind_eq_ok hs1
              cases ok_inj' hs1
          · cases ok_inj' hs1
        | inr _ =>
          try simp only at hc
          cases ok_inj' hc
  · cases ok_inj' hc

/-- Block `k` of `f` as `wf_code` checks it. -/
def GoodBlk (f : Func) (nb : Nat) (k : Nat) : Prop :=
  ∀ B : Block, f.blocks.val[k]? = some B → (k = 0 → B.phis.val = []) ∧
    ∀ s ∈ termSuccs B.term, 0 < s.val ∧ s.val < nb

theorem target_ok_true {nb s : Std.I32} {b : Bool} (h : target_ok nb s = ok b) (hb : b = true) :
    0 < s.val ∧ s.val < nb.val := by
  unfold target_ok at h
  rw [← ok_inj' h] at hb
  simp only [Bool.and_eq_true, decide_eq_true_eq] at hb
  exact ⟨hb.1, hb.2⟩

theorem wf_code_sound {f : Func} (h : wf_code f = ok 0#i32) : WFc f := by
  unfold wf_code at h
  obtain ⟨nb, hnb, h⟩ := bind_eq_ok h
  obtain ⟨hnb1, hnb2⟩ := arr_length_ok hnb
  split at h
  · exact absurd (ok_inj' h) (by decide)
  rename_i hnz
  have hpos : 0 < f.blocks.val.length := by
    rcases Nat.eq_zero_or_pos f.blocks.val.length with h0 | h0
    · exact absurd (i32_ext (by rw [hnb1, h0]; rfl)) hnz
    · exact h0
  split at h
  · exact absurd (ok_inj' h) (by decide)
  obtain ⟨td, htd, h⟩ := bind_eq_ok h
  split at h
  · exact absurd (ok_inj' h) (by decide)
  rename_i htd'
  have hdsts := dsts_ok_sound (by rw [htd]; simpa using htd')
  try simp only at h
  obtain ⟨s, hs, h⟩ := bind_eq_ok h
  have key := loop_ok_inv
    (fun (p : Std.I32 × Pion.Array Std.I32) => wf_code_loop0.body nb f f.ntemps p.1 p.2)
    (fun p => 0 ≤ p.1.val ∧ ∀ k, k < p.1.val.toNat → GoodBlk f f.blocks.val.length k)
    (fun s => match s with
      | .inl r => r ≠ 0#i32
      | .inr _ => ∀ k, k < f.blocks.val.length → GoodBlk f f.blocks.val.length k)
    (by
      rintro ⟨b, defs⟩ c ⟨hb0, hgood⟩ hc
      simp only at hb0 hgood hc
      unfold wf_code_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : b.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb1] using hlt
        obtain ⟨B, hB, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
        split at hc
        · rw [← ok_inj' hc]; show (3#i32 : Std.I32) ≠ 0#i32; decide
        obtain ⟨t4, ht4, hc⟩ := bind_eq_ok hc
        split at hc
        · rw [← ok_inj' hc]; show (4#i32 : Std.I32) ≠ 0#i32; decide
        rename_i ht4f
        obtain ⟨B5, hB5, hc⟩ := bind_eq_ok hc
        rw [hB] at hB5; cases ok_inj' hB5
        try simp only at hc
        obtain ⟨s1, hs1, hc⟩ := bind_eq_ok hc
        cases s1 with
        | inl r =>
          try simp only at hc
          rw [← ok_inj' hc]
          exact wf_loop1_early B.phis f.ntemps nb (0#i32, defs) r hs1
        | inr p1 =>
          obtain ⟨i1, defs1⟩ := p1
          try simp only at hc
          obtain ⟨B15, hB15, hc⟩ := bind_eq_ok hc
          rw [hB] at hB15; cases ok_inj' hB15
          obtain ⟨s2, hs2, hc⟩ := bind_eq_ok hc
          cases s2 with
          | inl r =>
            try simp only at hc
            rw [← ok_inj' hc]
            exact wf_loop3_early B.insts b f f.ntemps (0#i32, false, defs1) r hs2
          | inr p2 =>
            obtain ⟨i2, seen2, defs2⟩ := p2
            try simp only at hc
            obtain ⟨B24, hB24, hc⟩ := bind_eq_ok hc
            rw [hB] at hB24; cases ok_inj' hB24
            obtain ⟨s3, hs3, hc⟩ := bind_eq_ok hc
            -- the terminator's targets
            have hterm : (∃ r, s3 = .inl r ∧ r ≠ 0#i32) ∨
                (s3 = .inr () ∧ ∀ x ∈ termSuccs B.term, 0 < x.val ∧ x.val < f.blocks.val.length) := by
              generalize hT : B.term = T at hs3
              cases T with
              | Jmp x =>
                obtain ⟨t26, ht26, hs3⟩ := bind_eq_ok hs3
                split at hs3
                · left; exact ⟨_, (ok_inj' hs3).symm, by decide⟩
                · rename_i hn
                  right
                  refine ⟨(ok_inj' hs3).symm, fun y hy => ?_⟩
                  simp only [termSuccs, List.mem_singleton] at hy
                  subst hy
                  have := target_ok_true ht26 (by simpa using hn)
                  rw [hnb1] at this; exact this
              | Jnz a x1 x2 =>
                obtain ⟨t27, ht27, hs3⟩ := bind_eq_ok hs3
                obtain ⟨t29, ht29, hs3⟩ := bind_eq_ok hs3
                obtain ⟨t31, ht31, hs3⟩ := bind_eq_ok hs3
                split at hs3
                · left; exact ⟨_, (ok_inj' hs3).symm, by decide⟩
                · rename_i hn31
                  right
                  refine ⟨(ok_inj' hs3).symm, ?_⟩
                  split at ht31
                  · cases ok_inj' ht31; exact absurd rfl hn31
                  rename_i hn29
                  obtain ⟨t30, ht30, ht31⟩ := bind_eq_ok ht31
                  have e31 := ok_inj' ht31
                  split at ht29
                  · cases ok_inj' ht29; exact absurd rfl hn29
                  obtain ⟨t28, ht28, ht29⟩ := bind_eq_ok ht29
                  have e29 := ok_inj' ht29
                  have h1 := target_ok_true ht28 (by cases t28 <;> simp_all)
                  have h2 := target_ok_true ht30 (by cases t30 <;> simp_all)
                  intro y hy
                  simp only [termSuccs, List.mem_cons, List.not_mem_nil, or_false] at hy
                  rw [hnb1] at h1 h2
                  rcases hy with rfl | rfl
                  · exact h1
                  · exact h2
              | Ret _ _ a =>
                obtain ⟨t32, ht32, hs3⟩ := bind_eq_ok hs3
                split at hs3
                · left; exact ⟨_, (ok_inj' hs3).symm, by decide⟩
                · right; exact ⟨(ok_inj' hs3).symm, fun y hy => by simp [termSuccs] at hy⟩
              | Hlt =>
                right; exact ⟨(ok_inj' hs3).symm, fun y hy => by simp [termSuccs] at hy⟩
            rcases hterm with ⟨r, rfl, hr⟩ | ⟨rfl, hsucc⟩
            · simp only at hc
              rw [← ok_inj' hc]
              exact hr
            · simp only at hc
              rw [← ok_inj' hc]
              dsimp only
              have hs := i32_succ_val' hlt' hnb2
              refine ⟨by omega, fun k hk => ?_⟩
              by_cases hkb : k < b.val.toNat
              · exact hgood k hkb
              · have hk' : k = b.val.toNat := by omega
                subst hk'
                intro B' hB'
                rw [getElem?_toNat hb0 hBl, hBv] at hB'
                cases hB'
                refine ⟨fun hk0 => ?_, hsucc⟩
                have hb00 : b = 0#i32 := i32_ext (by simp; omega)
                subst hb00
                simp only [↓reduceIte] at ht4
                obtain ⟨B2, hB2, ht4⟩ := bind_eq_ok ht4
                rw [hB] at hB2; cases ok_inj' hB2
                obtain ⟨t3, ht3, ht4⟩ := bind_eq_ok ht4
                obtain ⟨ht31, -⟩ := arr_length_ok ht3
                rw [← ok_inj' ht4] at ht4f
                simp only [decide_eq_true_eq, not_lt] at ht4f
                have : B.phis.val.length = 0 := by
                  have : t3.val ≤ 0 := ht4f
                  omega
                exact List.eq_nil_of_length_eq_zero this
      · rename_i hge
        have hge' : f.blocks.val.length ≤ b.val := by simpa [i32_lt_iff, hnb1] using hge
        rw [← ok_inj' hc]
        exact fun k hk => hgood k (by omega))
  have hp := key _ s hs ⟨by simp, fun k hk => by simp at hk⟩
  cases s with
  | inl r =>
    try simp only at h
    exact absurd (ok_inj' h) hp
  | inr p =>
    refine ⟨hpos, hnb2, fun B hB => ((hp 0 hpos) B hB).1 rfl, fun b B hB => ?_, ?_⟩
    · have hbl : b < f.blocks.val.length := by
        by_contra hc
        rw [List.getElem?_eq_none (by omega)] at hB
        cases hB
      exact ((hp b hbl) B hB).2
    · exact hdsts

/-! ## `build_info` -/

/-- `reach` is closed under the CFG edges of `f`. -/
def ReachClosed (f : Func) (reach : List Bool) : Prop :=
  ∀ (p : Nat) (B : Block), f.blocks.val[p]? = some B → reach[p]? = some true →
    ∀ s ∈ termSuccs B.term, 0 ≤ s.val → s.val < f.blocks.val.length → reach[s.val.toNat]? = some true

/-- What the proof needs of `build_info f`. -/
structure InfoOK (f : Func) (info : FnInfo) : Prop where
  nb : info.nb.val = f.blocks.val.length
  nt : info.nt = f.ntemps
  reach_len : info.reach.val.length = f.blocks.val.length
  reach0 : info.reach.val[0]? = some true
  closed : ReachClosed f info.reach.val

theorem count_set_true : ∀ (l : List Bool) (i : Nat), l[i]? = some false →
    (l.set i true).count true = l.count true + 1
  | [], i, h => by simp at h
  | a :: l, 0, h => by
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h
    subst h
    simp
  | a :: l, i + 1, h => by
    simp only [List.getElem?_cons_succ] at h
    simp only [List.set_cons_succ, List.count_cons, count_set_true l i h]
    omega

theorem set_true_mono {l : List Bool} {i j : Nat} (h : l[j]? = some true) :
    (l.set i true)[j]? = some true := by
  have hj : j < l.length := by
    by_contra hc; rw [List.getElem?_eq_none (by omega)] at h; cases h
  rw [List.getElem?_set]
  split
  · rename_i e; subst e; simp [hj]
  · exact h

theorem count_pos_of {l : List Bool} {i : Nat} (h : l[i]? = some true) : 1 ≤ l.count true :=
  List.count_pos_iff.2 (List.mem_iff_getElem?.2 ⟨i, h⟩)

theorem reach_loop7 (n1 : Std.I32) (t : Term) (nb : Std.I32) (rin : Pion.Array Bool) (chin : Bool)
    (hn1 : n1.val = (termSuccs t).length) :
    ∀ (x : Std.I32 × Pion.Array Bool × Bool) r, build_info_loop7 n1 t nb x.1 x.2.1 x.2.2 = ok r →
      0 ≤ x.1.val →
      (x.2.1.val.length = rin.val.length ∧ (∀ j : Nat, rin.val[j]? = some true → x.2.1.val[j]? = some true) ∧
        rin.val.count true ≤ x.2.1.val.count true ∧
        (x.2.2 = true → chin = true ∨ rin.val.count true < x.2.1.val.count true) ∧
        (x.2.2 = false → chin = false ∧ x.2.1 = rin ∧ ∀ k, k < x.1.val.toNat → ∀ hk : k < (termSuccs t).length,
          0 ≤ ((termSuccs t)[k]).val → ((termSuccs t)[k]).val < nb.val →
          rin.val[((termSuccs t)[k]).val.toNat]? = some true)) →
      (r.2.1.val.length = rin.val.length ∧ (∀ j : Nat, rin.val[j]? = some true → r.2.1.val[j]? = some true) ∧
        rin.val.count true ≤ r.2.1.val.count true ∧
        (r.2.2 = true → chin = true ∨ rin.val.count true < r.2.1.val.count true) ∧
        (r.2.2 = false → chin = false ∧ r.2.1 = rin ∧ ∀ k, ∀ hk : k < (termSuccs t).length,
          0 ≤ ((termSuccs t)[k]).val → ((termSuccs t)[k]).val < nb.val →
          rin.val[((termSuccs t)[k]).val.toNat]? = some true)) := by
  intro x r h hx0 hinv
  unfold build_info_loop7 at h
  refine loop_ok_inv _
    (fun (x : Std.I32 × Pion.Array Bool × Bool) => 0 ≤ x.1.val ∧
      (x.2.1.val.length = rin.val.length ∧ (∀ j : Nat, rin.val[j]? = some true → x.2.1.val[j]? = some true) ∧
        rin.val.count true ≤ x.2.1.val.count true ∧
        (x.2.2 = true → chin = true ∨ rin.val.count true < x.2.1.val.count true) ∧
        (x.2.2 = false → chin = false ∧ x.2.1 = rin ∧ ∀ k, k < x.1.val.toNat → ∀ hk : k < (termSuccs t).length,
          0 ≤ ((termSuccs t)[k]).val → ((termSuccs t)[k]).val < nb.val →
          rin.val[((termSuccs t)[k]).val.toNat]? = some true)))
    (fun (r : Std.I32 × Pion.Array Bool × Bool) =>
      (r.2.1.val.length = rin.val.length ∧ (∀ j : Nat, rin.val[j]? = some true → r.2.1.val[j]? = some true) ∧
        rin.val.count true ≤ r.2.1.val.count true ∧
        (r.2.2 = true → chin = true ∨ rin.val.count true < r.2.1.val.count true) ∧
        (r.2.2 = false → chin = false ∧ r.2.1 = rin ∧ ∀ k, ∀ hk : k < (termSuccs t).length,
          0 ≤ ((termSuccs t)[k]).val → ((termSuccs t)[k]).val < nb.val →
          rin.val[((termSuccs t)[k]).val.toNat]? = some true)))
    ?_ x r h ⟨hx0, hinv⟩
  rintro ⟨k, reach, ch⟩ c ⟨hk0, hl, hmono, hcnt, hch, hnch⟩ hc
  simp only at hk0 hl hmono hcnt hch hnch hc
  unfold build_info_loop7.body at hc
  split at hc
  · rename_i hlt
    have hlt' : k.val < (termSuccs t).length := by simpa [i32_lt_iff, hn1] using hlt
    rw [term_succ_spec t k hk0 hlt'] at hc
    simp only [bind_ok] at hc
    generalize hs : (termSuccs t)[k.val.toNat] = sk at hc
    obtain ⟨t34, ht34, hc⟩ := bind_eq_ok hc
    obtain ⟨p, hp, hc⟩ := bind_eq_ok hc
    obtain ⟨reach1, ch1⟩ := p
    rw [← ok_inj' hc]
    have hks := i32_succ_val' hlt' (by have := termSuccs_len t; omega)
    dsimp only
    split at hp
    · -- a new reachable block
      rename_i ht
      obtain ⟨r2, hr2, hp⟩ := bind_eq_ok hp
      cases ok_inj' hp
      split at ht34
      · rename_i hrange
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hrange
        obtain ⟨x, hx, ht34⟩ := bind_eq_ok ht34
        obtain ⟨_, hxl, hxv⟩ := arr_get_ok hx
        rw [← ok_inj' ht34] at ht
        simp only [Bool.not_eq_true'] at ht
        have hfalse : reach.val[sk.val.toNat]? = some false := by
          rw [List.getElem?_eq_getElem hxl, hxv, ht]
        have hr2' := arr_set_ok hr2
        refine ⟨by omega, by rw [hr2']; simp [hl], fun j hj => by rw [hr2']; exact set_true_mono (hmono j hj),
          ?_, fun _ => Or.inr ?_, fun e => by cases e⟩
        · rw [hr2', count_set_true _ _ hfalse]; omega
        · rw [hr2', count_set_true _ _ hfalse]; omega
      · cases ok_inj' ht34; cases ht
    · rename_i ht
      cases ok_inj' hp
      refine ⟨by omega, hl, hmono, hcnt, hch, fun hf => ?_⟩
      obtain ⟨hchin, hre, hall⟩ := hnch hf
      refine ⟨hchin, hre, fun k' hk' hk'' h0 h1 => ?_⟩
      by_cases hkk : k' < k.val.toNat
      · exact hall k' hkk hk'' h0 h1
      · have : k' = k.val.toNat := by omega
        subst this
        rw [hs] at h0 h1 ⊢
        split at ht34
        · obtain ⟨x, hx, ht34⟩ := bind_eq_ok ht34
          obtain ⟨_, hxl, hxv⟩ := arr_get_ok hx
          rw [← ok_inj' ht34] at ht
          simp only [Bool.not_eq_true', Bool.not_eq_false] at ht
          rw [← hre, List.getElem?_eq_getElem hxl, hxv, ht]
        · rename_i hrange
          simp only [Bool.and_eq_true, decide_eq_true_eq, not_and, not_lt] at hrange
          exfalso
          have h2 : nb.val ≤ sk.val := hrange h0
          omega
  · rename_i hge
    have hge' : (termSuccs t).length ≤ k.val := by simpa [i32_lt_iff, hn1] using hge
    rw [← ok_inj' hc]
    refine ⟨hl, hmono, hcnt, hch, fun hf => ?_⟩
    obtain ⟨hchin, hre, hall⟩ := hnch hf
    exact ⟨hchin, hre, fun k' hk' => hall k' (by omega) hk'⟩

theorem reach_loop6 (nb : Std.I32) (f : Func) (r0 : Pion.Array Bool) (hnb : nb.val = f.blocks.val.length) :
    ∀ (x : Std.I32 × Pion.Array Bool × Bool) r, build_info_loop6 nb f x.1 x.2.1 x.2.2 = ok r →
      0 ≤ x.1.val →
      (x.2.1.val.length = r0.val.length ∧ (∀ j : Nat, r0.val[j]? = some true → x.2.1.val[j]? = some true) ∧
        r0.val.count true ≤ x.2.1.val.count true ∧
        (x.2.2 = true → r0.val.count true < x.2.1.val.count true) ∧
        (x.2.2 = false → x.2.1 = r0 ∧ ∀ p, p < x.1.val.toNat → ∀ B : Block, f.blocks.val[p]? = some B →
          r0.val[p]? = some true → ∀ s ∈ termSuccs B.term, 0 ≤ s.val → s.val < nb.val →
          r0.val[s.val.toNat]? = some true)) →
      (r.2.1.val.length = r0.val.length ∧ (∀ j : Nat, r0.val[j]? = some true → r.2.1.val[j]? = some true) ∧
        (r.2.2 = true → r0.val.count true < r.2.1.val.count true) ∧
        (r.2.2 = false → r.2.1 = r0 ∧ ∀ p, p < nb.val.toNat → ∀ B : Block, f.blocks.val[p]? = some B →
          r0.val[p]? = some true → ∀ s ∈ termSuccs B.term, 0 ≤ s.val → s.val < nb.val →
          r0.val[s.val.toNat]? = some true)) := by
  intro x r h hx0 hinv
  unfold build_info_loop6 at h
  refine loop_ok_inv _
    (fun (x : Std.I32 × Pion.Array Bool × Bool) => 0 ≤ x.1.val ∧
      (x.2.1.val.length = r0.val.length ∧ (∀ j : Nat, r0.val[j]? = some true → x.2.1.val[j]? = some true) ∧
        r0.val.count true ≤ x.2.1.val.count true ∧
        (x.2.2 = true → r0.val.count true < x.2.1.val.count true) ∧
        (x.2.2 = false → x.2.1 = r0 ∧ ∀ p, p < x.1.val.toNat → ∀ B : Block, f.blocks.val[p]? = some B →
          r0.val[p]? = some true → ∀ s ∈ termSuccs B.term, 0 ≤ s.val → s.val < nb.val →
          r0.val[s.val.toNat]? = some true)))
    (fun (r : Std.I32 × Pion.Array Bool × Bool) =>
      (r.2.1.val.length = r0.val.length ∧ (∀ j : Nat, r0.val[j]? = some true → r.2.1.val[j]? = some true) ∧
        (r.2.2 = true → r0.val.count true < r.2.1.val.count true) ∧
        (r.2.2 = false → r.2.1 = r0 ∧ ∀ p, p < nb.val.toNat → ∀ B : Block, f.blocks.val[p]? = some B →
          r0.val[p]? = some true → ∀ s ∈ termSuccs B.term, 0 ≤ s.val → s.val < nb.val →
          r0.val[s.val.toNat]? = some true)))
    ?_ x r h ⟨hx0, hinv⟩
  rintro ⟨xb, reach, ch⟩ c ⟨hx0, hl, hmono, hcnt, hch, hnch⟩ hc
  simp only at hx0 hl hmono hcnt hch hnch hc
  unfold build_info_loop6.body at hc
  split at hc
  · rename_i hlt
    have hlt' : xb.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb] using hlt
    obtain ⟨t29, ht29, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hxl, hxv⟩ := arr_get_ok ht29
    obtain ⟨p, hp, hc⟩ := bind_eq_ok hc
    obtain ⟨reach1, ch1⟩ := p
    rw [← ok_inj' hc]
    dsimp only
    have hxs := i32_succ_val' hlt' (by have := i32_val_le nb; omega)
    split at hp
    · rename_i htt
      obtain ⟨B, hB, hp⟩ := bind_eq_ok hp
      obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
      simp only [term_nsucc_spec, bind_ok] at hp
      obtain ⟨q, hq, hp⟩ := bind_eq_ok hp
      obtain ⟨k2, r2, c2⟩ := q
      cases ok_inj' hp
      have h7 := reach_loop7 _ B.term nb reach ch (nsucc_val B.term) (0#i32, reach, ch) _ hq (by simp)
        ⟨rfl, fun j hj => hj, le_refl _, fun e => Or.inl e, fun e => ⟨e, rfl, fun k hk => by simp at hk⟩⟩
      obtain ⟨h7l, h7m, h7c, h7ch, h7n⟩ := h7
      dsimp only at h7l h7m h7c h7ch h7n
      refine ⟨by omega, by rw [h7l, hl], fun j hj => h7m j (hmono j hj), by omega, fun e => ?_, fun e => ?_⟩
      · rcases h7ch e with e' | e'
        · have := hch e'; omega
        · omega
      · obtain ⟨hchin, hre, hall⟩ := h7n e
        obtain ⟨hre0, hall0⟩ := hnch hchin
        subst hre
        refine ⟨hre0, fun p hp B' hB' hr s hs h0 h1 => ?_⟩
        by_cases hpx : p < xb.val.toNat
        · exact hall0 p hpx B' hB' hr s hs h0 h1
        · have : p = xb.val.toNat := by omega
          subst this
          rw [getElem?_toNat hx0 hBl, hBv] at hB'
          cases hB'
          obtain ⟨k, hk, hks⟩ := List.getElem_of_mem hs
          have := hall k hk (by rw [hks]; exact h0) (by rw [hks]; exact h1)
          rw [hks, hre0] at this
          exact this
    · rename_i htf
      cases ok_inj' hp
      refine ⟨by omega, hl, hmono, hcnt, hch, fun e => ?_⟩
      obtain ⟨hre, hall⟩ := hnch e
      refine ⟨hre, fun p hp B' hB' hr s hs h0 h1 => ?_⟩
      by_cases hpx : p < xb.val.toNat
      · exact hall p hpx B' hB' hr s hs h0 h1
      · have : p = xb.val.toNat := by omega
        subst this
        rw [← hre, List.getElem?_eq_getElem hxl, hxv] at hr
        cases hr
        exact absurd rfl htf
  · rename_i hge
    have hge' : f.blocks.val.length ≤ xb.val := by simpa [i32_lt_iff, hnb] using hge
    rw [← ok_inj' hc]
    refine ⟨hl, hmono, hch, fun e => ?_⟩
    obtain ⟨hre, hall⟩ := hnch e
    exact ⟨hre, fun p hp => hall p (by omega)⟩

theorem build_info_sound {f : Func} {info : FnInfo} (h : build_info f = ok info) : InfoOK f info := by
  unfold build_info at h
  obtain ⟨nb, hnb, h⟩ := bind_eq_ok h
  obtain ⟨hnb1, hnb2⟩ := arr_length_ok hnb
  try simp only at h
  obtain ⟨q0, -, h⟩ := bind_eq_ok h
  obtain ⟨b1, dk1, db1, di1, ninst1⟩ := q0
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q3, -, h⟩ := bind_eq_ok h
  obtain ⟨y1, npred1⟩ := q3
  try simp only [uncurry_apply_pair] at h
  obtain ⟨reach1, hr1, h⟩ := bind_eq_ok h
  obtain ⟨q5, hq5, h⟩ := bind_eq_ok h
  obtain ⟨changed1, rounds1, reach2⟩ := q5
  cases ok_inj' h
  have hr1' := arr_set_ok hr1
  have hlen0 : 0 < f.blocks.val.length := by
    unfold Pion.Array.set listSet at hr1
    split at hr1
    · rename_i hb
      simp only [inBounds, Pion.Array.make, listMake, List.length_replicate] at hb
      omega
    · simp at hr1
  have hnbn : nb.val.toNat = f.blocks.val.length := by omega
  have hl1 : reach1.val.length = f.blocks.val.length := by
    rw [hr1']; simp [Pion.Array.make, listMake, hnbn]
  have h01 : reach1.val[0]? = some true := by
    rw [hr1']; simp [Pion.Array.make, listMake, hnbn, hlen0]
  unfold build_info_loop5 at hq5
  have key := loop_ok_inv (fun (x : Bool × Std.I32 × Pion.Array Bool) =>
      match x with | (changed, rounds, reach) => build_info_loop5.body nb f changed rounds reach)
    (fun (x : Bool × Std.I32 × Pion.Array Bool) => x.2.2.val.length = f.blocks.val.length ∧
      x.2.2.val[0]? = some true ∧
      (x.1 = true → 0 ≤ x.2.1.val ∧ x.2.1.val + 1 ≤ x.2.2.val.count true) ∧
      (x.1 = false → ReachClosed f x.2.2.val))
    (fun (x : Bool × Std.I32 × Pion.Array Bool) => x.2.2.val.length = f.blocks.val.length ∧
      x.2.2.val[0]? = some true ∧ ReachClosed f x.2.2.val)
    (by
      rintro ⟨ch, rounds, reach⟩ c ⟨hl, h0, hch, hnch⟩ hc
      simp only at hl h0 hch hnch hc
      unfold build_info_loop5.body at hc
      split at hc
      · rename_i hcond
        simp only [Bool.and_eq_true, decide_eq_true_eq] at hcond
        obtain ⟨hct, hrle⟩ := hcond
        obtain ⟨hr0, hrc⟩ := hch hct
        try simp only at hc
        obtain ⟨q, hq, hc⟩ := bind_eq_ok hc
        obtain ⟨x1, reach3, ch2⟩ := q
        rw [← ok_inj' hc]
        dsimp only
        have h6 := reach_loop6 nb f reach hnb1 (0#i32, reach, false) _ hq (by simp)
          ⟨rfl, fun j hj => hj, le_refl _, fun e => (by simp at e), fun _ => ⟨rfl, fun p hp => by simp at hp⟩⟩
        obtain ⟨h6l, h6m, h6ch, h6n⟩ := h6
        dsimp only at h6l h6m h6ch h6n
        refine ⟨by rw [h6l, hl], h6m 0 h0, fun e => ?_, fun e => ?_⟩
        · have hlt := h6ch e
          have hle := List.count_le_length (a := true) (l := reach3.val)
          rw [h6l, hl] at hle
          have hrs : (Pion.I32.add rounds 1#i32).val = rounds.val + 1 :=
            i32_succ_val' (m := f.blocks.val.length) (by omega) hnb2
          rw [hrs]
          omega
        · obtain ⟨hre, hall⟩ := h6n e
          subst hre
          intro p B hB hp s hs h0' h1'
          have hpl : p < f.blocks.val.length := by
            by_contra hc'; rw [List.getElem?_eq_none (by omega)] at hB; cases hB
          exact hall p (by omega) B hB hp s hs h0' (by omega)
      · rename_i hcond
        rw [← ok_inj' hc]
        refine ⟨hl, h0, ?_⟩
        cases ch with
        | false => exact hnch rfl
        | true =>
          exfalso
          simp only [Bool.true_and, decide_eq_true_eq, not_le, i32_lt_iff] at hcond
          obtain ⟨hr0, hrc⟩ := hch rfl
          have hle := List.count_le_length (a := true) (l := reach.val)
          rw [hl] at hle
          omega)
  obtain ⟨hl2, h02, hcl⟩ := key _ _ hq5 (by
    dsimp only
    refine ⟨hl1, h01, fun _ => ⟨by simp, ?_⟩, fun e => by simp at e⟩
    have := count_pos_of h01
    simp only [i32_zero_val]
    omega)
  exact ⟨hnb1, rfl, hl2, h02, hcl⟩

/-! ## Operand classes -/

theorem unop_arg_cls_spec (op : UnOp) (c : Cls) : unop_arg_cls op c = ok (unArgCls op c) := by
  cases op <;> rfl

theorem binop_arg_cls_spec0 (op : BinOp) (c : Cls) :
    binop_arg_cls op c 0#i32 = ok (binArgCls op c 0) := by
  cases op <;> simp [binop_arg_cls, binop_is_cmp, binop_cmp_cls, binop_is_shift, binArgCls]

theorem binop_arg_cls_spec1 (op : BinOp) (c : Cls) :
    binop_arg_cls op c 1#i32 = ok (binArgCls op c 1) := by
  cases op <;> simp [binop_arg_cls, binop_is_cmp, binop_cmp_cls, binop_is_shift, binArgCls]

/-- The operators that may trap (`is_trapping_binop`). -/
def trapOp : BinOp → Bool
  | .Div | .UDiv | .Rem | .URem => true
  | _ => false

theorem is_trapping_binop_spec (op : BinOp) : is_trapping_binop op = ok (trapOp op) := by
  cases op <;> rfl

/-- An `if` whose arms are both `some` is never `none` (the `s = 0` split of `Ror`). -/
theorem ite_some_some_ne_none {α : Type} (p : Prop) [Decidable p] (a b : α) :
    ¬((if p then some a else some b) = none) := by
  split <;> simp

theorem evalBin_some_of_not_trap {op : BinOp} (h : trapOp op = false) (c : Cls) (x y : BitVec 64) :
    evalBin c op x y ≠ none := by
  cases op <;> simp [trapOp] at h <;> simp [evalBin, ite_some_some_ne_none]

theorem asS_maskC (c : Cls) (x : BitVec 64) : asS c (maskC c x) = asS c x := by
  cases c
  · simp only [asS, maskC, extS, zx32, lo32]
    congr 1
    apply BitVec.eq_of_getLsbD_eq
    intro i hi
    simp [hi, show i < 64 by omega]
  · rfl

theorem maskC_neg_maskC (c : Cls) (x : BitVec 64) : maskC c (-(maskC c x)) = maskC c (-x) := by
  cases c
  · simp only [maskC, lo32_neg, lo32_zx32]
  · rfl

/-- Reading the operand of `cls op a` at `unop_arg_cls op cls` keeps the value. -/
theorem evalUn_argmask (c : Cls) (op : UnOp) (x : BitVec 64) :
    evalUn c op (maskC (unArgCls op c) x) = evalUn c op x := by
  cases op with
  | Copy => simp only [unArgCls, evalUn, maskC_idem]
  | Neg => simp only [unArgCls, evalUn, maskC_neg_maskC]
  | _ =>
    simp only [unArgCls]
    exact evalUn_low c _ (by simp [extBits]) (fun i hi => maskC_low .W x i
      (by simp only [extBits] at hi; omega))

/-- Reading the operands of `cls op a, b` at `binop_arg_cls` keeps the value. -/
theorem evalBin_argmask (c : Cls) (op : BinOp) (x y : BitVec 64) :
    evalBin c op (maskC (binArgCls op c 0) x) (maskC (binArgCls op c 1) y) = evalBin c op x y := by
  cases op <;> simp [evalBin, binArgCls, maskC_idem, shAmt_maskW, asS_maskC]

/-! ## `bin_safe` -/

theorem vg_const_some {vg : ValGraph} {v : Std.I32} {y : Std.U64} (h : vg_const vg v = ok (some y)) :
    constOf vg v = some y.bv ∧ vg.nodes.val.length ≤ 2147483647 := by
  have hl : vg.nodes.val.length ≤ 2147483647 := by
    unfold vg_const at h
    obtain ⟨b, hb, h⟩ := bind_eq_ok h
    obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
    cases b with
    | false => simp at h
    | true => exact hb2 rfl
  rw [vg_const_eq hl] at h
  refine ⟨?_, hl⟩
  revert h
  cases constOf vg v with
  | none => intro h; simp at h
  | some x => intro h; simp only [Option.map_some, ok.injEq, Option.some.injEq] at h; subst h; rfl

theorem vg_const_none_or {vg : ValGraph} {v : Std.I32} {o : Option Std.U64} (h : vg_const vg v = ok o) :
    ∀ y, o = some y → constOf vg v = some y.bv := by
  intro y hy
  subst hy
  exact (vg_const_some h).1

/-- A division `bin_safe` accepts never traps on the values of its operands. -/
theorem bin_safe_sound {vg : ValGraph} {c : Cls} {op : BinOp} {av bv : Std.I32}
    (h : bin_safe vg c op av bv = ok true) (hd : ValGraphDAG vg) (env : SymEnv) :
    evalBin c op (evI vg env av) (evI vg env bv) ≠ none := by
  unfold bin_safe at h
  obtain ⟨ob, hob, h⟩ := bind_eq_ok h
  cases ob with
  | none => simp at h
  | some y =>
    try simp only at h
    obtain ⟨hy, -⟩ := vg_const_some hob
    have hbv := constOf_evI hd env hy
    obtain ⟨oa, hoa, h⟩ := bind_eq_ok h
    obtain ⟨r, hr, h⟩ := bind_eq_ok h
    have hrt : r = true := ok_inj' h
    subst hrt
    rw [hbv]
    -- the safety condition, for any value of the left operand
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
    have hs := hsafe (evI vg env av) (fun l hl => (constOf_evI hd env (vg_const_none_or hoa l hl)))
    have hsm : safeDiv c op (maskC c (evI vg env av)) (maskC c y.bv) := by
      unfold safeDiv at hs ⊢
      simp only [maskC_idem]
      exact hs
    cases op <;> simp [evalBin, hsm, ite_some_some_ne_none]

/-! ## Branch facts and `apply_facts` -/

/-- Every fact of `fs` holds under `env`: its value is zero (`zero`) or not. -/
def FactsHold (vg : ValGraph) (env : SymEnv) (fs : List Fact) : Prop :=
  ∀ fa ∈ fs, Valid vg fa.vid ∧ (fa.zero = true → evI vg env fa.vid = 0) ∧
    (fa.zero = false → evI vg env fa.vid ≠ 0)

/-- One fact holds under `env`. -/
def FactOK (vg : ValGraph) (env : SymEnv) (fa : Fact) : Prop :=
  Valid vg fa.vid ∧ (fa.zero = true → evI vg env fa.vid = 0) ∧ (fa.zero = false → evI vg env fa.vid ≠ 0)

theorem factOK_extends {vg vg' : ValGraph} (hp : vg_extends vg vg') {env : SymEnv} {fa : Fact}
    (h : FactOK vg env fa) : FactOK vg' env fa := by
  obtain ⟨hv, h1, h2⟩ := h
  exact ⟨extends_valid hp hv, by rw [extends_evI hp env hv]; exact h1,
    by rw [extends_evI hp env hv]; exact h2⟩

theorem vg_is_const_true {vg : ValGraph} {v : Std.I32} {x : Std.U64} (h : vg_is_const vg v x = ok true) :
    constOf vg v = some x.bv ∧ vg.nodes.val.length ≤ 2147483647 := by
  unfold vg_is_const at h
  obtain ⟨o, ho, h⟩ := bind_eq_ok h
  cases o with
  | none => cases ok_inj' h
  | some y =>
    simp only at h
    have hyx : y = x := by simpa using (ok_inj' h).symm
    subst hyx
    exact vg_const_some ho

theorem factsHold_extends {vg vg' : ValGraph} (hp : vg_extends vg vg') {env : SymEnv}
    {fs : List Fact} (h : FactsHold vg env fs) : FactsHold vg' env fs := by
  intro fa hfa
  obtain ⟨hv, h1, h2⟩ := h fa hfa
  exact ⟨extends_valid hp hv, by rw [extends_evI hp env hv]; exact h1,
    by rw [extends_evI hp env hv]; exact h2⟩

theorem factsHold_sub {vg : ValGraph} {env : SymEnv} {fs fs' : List Fact} (h : FactsHold vg env fs)
    (hs : ∀ fa ∈ fs', fa ∈ fs) : FactsHold vg env fs' := fun fa hfa => h fa (hs fa hfa)

theorem maskC_zero (c : Cls) : maskC c 0 = 0 := by cases c <;> decide

theorem maskC_one (c : Cls) : maskC c 1 = 1 := by cases c <;> decide

theorem isCmp_getD {op : BinOp} (h : isCmp op = true) (c : Cls) (x y : BitVec 64) :
    (evalBin c op x y).getD 0 = 0 ∨ (evalBin c op x y).getD 0 = 1 := by
  cases op <;> simp [isCmp] at h <;> simp only [evalBin, Option.getD_some, b2v] <;> split <;> simp

theorem bv_one : (1#u64 : Std.U64).bv = 1 := rfl

theorem maskC_bv0 (c : Cls) : maskC c (0#u64 : Std.U64).bv = 0 := by cases c <;> rfl

theorem maskC_bv1 (c : Cls) : maskC c (1#u64 : Std.U64).bv = 1 := by cases c <;> rfl

/-- `fact_post` replaces a node by a constant the facts give it. -/
theorem fact_post_sound {vg : ValGraph} {fs : Pion.Array Fact} {r : Std.I32} {p : Std.I32 × ValGraph}
    (h : fact_post vg fs r = ok p) (hd : ValGraphDAG vg) (hr : Valid vg r) :
    vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧ Valid p.2 p.1 ∧
      ∀ G env, vg_extends p.2 G → FactsHold G env fs.val → evI p.2 env p.1 = evI vg env r := by
  unfold fact_post at h
  obtain ⟨b, hb, h⟩ := bind_eq_ok h
  obtain ⟨hb1, hb2⟩ := vg_valid_ok hb
  have hbt : b = true := hb1.2 hr
  subst hbt
  have hl := hb2 rfl
  simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte, vg_cls_eq hl, bind_ok] at h
  have hid : ∀ q : Std.I32 × ValGraph, (r, vg) = q → vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      Valid q.2 q.1 ∧ ∀ G env, vg_extends q.2 G → FactsHold G env fs.val → evI q.2 env q.1 = evI vg env r := by
    rintro q rfl; exact ⟨vg_extends_refl _, hd, hr, fun _ _ _ _ => rfl⟩
  have hk : ∀ (x : Std.U64) (q : Std.I32 × ValGraph), vg_konst vg (clsOf vg r) x = ok q →
      (∀ G env, vg_extends vg G → FactsHold G env fs.val → maskC (clsOf vg r) x.bv = evI vg env r) →
      vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ Valid q.2 q.1 ∧
        ∀ G env, vg_extends q.2 G → FactsHold G env fs.val → evI q.2 env q.1 = evI vg env r := by
    rintro x ⟨r', vg'⟩ hq hv
    obtain ⟨h1, h2, h3, -, -, h6⟩ := konst_facts hd hq
    exact ⟨h1, h2, h3, fun G env hG hf => by rw [h6]; exact hv G env (vg_extends_trans h1 hG) hf⟩
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  have ht2' := fact_in_spec ht2
  split at h
  · rename_i htt
    obtain ⟨fa, hfa, hfv, hfz⟩ := ht2'.1 htt
    refine hk _ p (pair_ok h) (fun G env hG hf => ?_)
    have := (hf fa hfa).2.1 hfz
    rw [hfv, extends_evI hG env hr] at this
    rw [this]; exact maskC_bv0 _
  obtain ⟨n, hn, h⟩ := bind_eq_ok h
  have hnode := nodes_get_ok hn
  cases n
  case SBin c0 op x y =>
    simp only [binop_is_cmp_spec, bind_ok] at h
    have hval : ∀ env, evI vg env r = (evalBin c0 op (evI vg env x) (evI vg env y)).getD 0 := by
      intro env; rw [evI_node hd env hnode]; rfl
    split at h
    · rename_i hcmp
      obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
      have ht7' := fact_in_spec ht7
      split at h
      · rename_i htt
        obtain ⟨fa, hfa, hfv, hfz⟩ := ht7'.1 htt
        refine hk _ p (pair_ok h) (fun G env hG hf => ?_)
        have hne := (hf fa hfa).2.2 hfz
        rw [hfv, extends_evI hG env hr] at hne
        refine (maskC_bv1 _).trans ?_
        rcases isCmp_getD hcmp c0 (evI vg env x) (evI vg env y) with e | e
        · rw [hval env, e] at hne; exact absurd rfl hne
        · rw [hval env, e]
      · rw [vg_is_const_eq hl] at h
        simp only [bind_ok] at h
        obtain ⟨t12, ht12, h⟩ := bind_eq_ok h
        split at h
        · rename_i h12
          have hy0 : constOf vg y = some 0 := by
            split at ht12
            · rename_i hc; simpa [bv_zero] using hc
            · cases ok_inj' ht12; cases h12
          have hxf : ∃ fa ∈ fs.val, fa.vid = x ∧ fa.zero = false := by
            split at ht12
            · obtain ⟨t11, ht11, ht12⟩ := bind_eq_ok ht12
              cases ok_inj' ht12
              exact (fact_in_spec ht11).1 h12
            · cases ok_inj' ht12; cases h12
          obtain ⟨fa, hfa, hfv, hfz⟩ := hxf
          have hxv : Valid vg x := (child_bin hd hnode).1
          have hsem : ∀ G env, vg_extends vg G → FactsHold G env fs.val →
              evI vg env y = 0 ∧ evI vg env x ≠ 0 ∧ Valid vg x := by
            intro G env hG hf
            obtain ⟨hv, -, h2⟩ := hf fa hfa
            rw [hfv] at hv h2
            rw [extends_evI hG env hxv] at h2
            exact ⟨constOf_evI hd env hy0, h2 hfz, hxv⟩
          cases op
          case CEq cc =>
            simp only at h
            split at h
            · rename_i hcc
              simp only [beq_iff_eq] at hcc
              refine hk _ p (pair_ok h) (fun G env hG hf => ?_)
              obtain ⟨hy, hx, hvx⟩ := hsem G env hG hf
              refine (maskC_bv0 _).trans ?_
              rw [hval env, hy]
              have hm := evI_masked hd env hvx
              rw [hcc] at hm
              simp only [evalBin, Option.getD_some, b2v, maskC_zero, hm]
              simpa using hx
            · exact hid p (ok_inj' h)
          case CNe cc =>
            simp only at h
            split at h
            · rename_i hcc
              simp only [beq_iff_eq] at hcc
              refine hk _ p (pair_ok h) (fun G env hG hf => ?_)
              obtain ⟨hy, hx, hvx⟩ := hsem G env hG hf
              refine (maskC_bv1 _).trans ?_
              rw [hval env, hy]
              have hm := evI_masked hd env hvx
              rw [hcc] at hm
              simp only [evalBin, Option.getD_some, b2v, maskC_zero, hm]
              simpa using hx
            · exact hid p (ok_inj' h)
          all_goals exact hid p (ok_inj' h)
        · exact hid p (ok_inj' h)
    · exact hid p (ok_inj' h)
  all_goals simp only at h; exact hid p (ok_inj' h)

/-- The children (below `k`) of node `k` are marked. -/
def ChildMarked (vg : ValGraph) (mark : List Bool) (k : Nat) : Prop :=
  ∀ n, vg.nodes.val[k]? = some n →
    match n with
    | .SUn _ _ a => 0 ≤ a.val → a.val.toNat < k → mark[a.val.toNat]? = some true
    | .SBin _ _ a b => (0 ≤ a.val → a.val.toNat < k → mark[a.val.toNat]? = some true) ∧
        (0 ≤ b.val → b.val.toNat < k → mark[b.val.toNat]? = some true)
    | _ => True

theorem childMarked_mono {vg : ValGraph} {mark mark' : List Bool} {k : Nat}
    (hm : ∀ j : Nat, mark[j]? = some true → mark'[j]? = some true)
    (h : ChildMarked vg mark k) : ChildMarked vg mark' k := by
  intro n hn
  have := h n hn
  cases n
  case SUn c op a => exact fun h1 h2 => hm _ (this h1 h2)
  case SBin c op a b => exact ⟨fun h1 h2 => hm _ (this.1 h1 h2), fun h1 h2 => hm _ (this.2 h1 h2)⟩
  all_goals trivial

theorem getElem?_set_true_self {l : List Bool} {a : Nat} (h : a < l.length) :
    (l.set a true)[a]? = some true := by simp [h]

theorem getElem?_set_ne' {l : List Bool} {a k : Nat} (h : a ≠ k) (x : Bool) :
    (l.set a x)[k]? = l[k]? := by simp [h]

/-- The backward marking sweep of `apply_facts` marks every child of a marked node. -/
theorem mark_loop {vg : ValGraph} {v : Std.I32} (hv : Valid vg v) :
    ∀ (x : Std.I32 × Pion.Array Bool) r, apply_facts_loop0 vg x.1 x.2 = ok r →
      (-1 ≤ x.1.val ∧ x.1.val ≤ v.val ∧ x.2.val.length = v.val.toNat + 1 ∧
        x.2.val[v.val.toNat]? = some true ∧
        ∀ k : Nat, x.1.val < k → k ≤ v.val.toNat → x.2.val[k]? = some true → ChildMarked vg x.2.val k) →
      r.2.val.length = v.val.toNat + 1 ∧ r.2.val[v.val.toNat]? = some true ∧
        ∀ k : Nat, k ≤ v.val.toNat → r.2.val[k]? = some true → ChildMarked vg r.2.val k := by
  intro x r h hx
  unfold apply_facts_loop0 at h
  refine loop_ok_inv (fun (x : Std.I32 × Pion.Array Bool) =>
      match x with | (i, mark) => apply_facts_loop0.body vg i mark)
    (fun (x : Std.I32 × Pion.Array Bool) => -1 ≤ x.1.val ∧ x.1.val ≤ v.val ∧
      x.2.val.length = v.val.toNat + 1 ∧ x.2.val[v.val.toNat]? = some true ∧
      ∀ k : Nat, x.1.val < k → k ≤ v.val.toNat → x.2.val[k]? = some true → ChildMarked vg x.2.val k)
    (fun (r : Std.I32 × Pion.Array Bool) => r.2.val.length = v.val.toNat + 1 ∧
      r.2.val[v.val.toNat]? = some true ∧
      ∀ k : Nat, k ≤ v.val.toNat → r.2.val[k]? = some true → ChildMarked vg r.2.val k) ?_ x r h hx
  rintro ⟨i, mark⟩ c ⟨hi1, hiv, hl, hmv, hcm⟩ hc
  simp only at hi1 hiv hl hmv hcm hc
  unfold apply_facts_loop0.body at hc
  split at hc
  · rename_i hge
    have hi0 : 0 ≤ i.val := by simpa [i32_le_iff] using hge
    have hiN : i.val.toNat < vg.nodes.val.length := by have := hv.2; omega
    obtain ⟨t5, ht5, hc⟩ := bind_eq_ok hc
    obtain ⟨_, ht5l, ht5v⟩ := arr_get_ok ht5
    obtain ⟨mark1, hm1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    dsimp only
    have hsub := i32_sub_val i 1#i32 (by simp; omega) (by have := i32_val_le i; simp; omega)
    simp only [i32_one_val] at hsub
    -- what one step of marking does
    have claim : mark1.val.length = mark.val.length ∧
        (∀ j : Nat, mark.val[j]? = some true → mark1.val[j]? = some true) ∧
        (∀ k : Nat, i.val.toNat ≤ k → mark1.val[k]? = mark.val[k]?) ∧
        (t5 = true → ChildMarked vg mark1.val i.val.toNat) := by
      split at hm1
      · rename_i htt
        obtain ⟨nd, hnd, hm1⟩ := bind_eq_ok hm1
        have hnode := nodes_get_ok hnd
        simp only [nodeAt, hi0, ↓reduceIte] at hnode
        cases nd
        case SUn c op a =>
          simp only at hm1
          split at hm1
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val] at hcond
            obtain ⟨m2, hm2, hm1⟩ := bind_eq_ok hm1
            cases ok_inj' hm1
            have hm2' := arr_set_ok hm2
            have hal : a.val.toNat < mark.val.length := by rw [hl]; omega
            refine ⟨by rw [hm2']; simp, fun j hj => by rw [hm2']; exact set_true_mono hj,
              fun k hk => by rw [hm2']; exact getElem?_set_ne' (by omega) _, fun _ n hn => ?_⟩
            rw [hnode] at hn; cases hn
            intro _ _
            rw [hm2']; exact getElem?_set_true_self hal
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val,
              not_and, not_lt] at hcond
            cases ok_inj' hm1
            refine ⟨rfl, fun j hj => hj, fun k hk => rfl, fun _ n hn => ?_⟩
            rw [hnode] at hn; cases hn
            intro h1 h2; exact absurd (hcond h1) (by omega)
        case SBin c op a b =>
          simp only at hm1
          obtain ⟨m3, hm3, hm1⟩ := bind_eq_ok hm1
          have c3 : m3.val.length = mark.val.length ∧
              (∀ j : Nat, mark.val[j]? = some true → m3.val[j]? = some true) ∧
              (∀ k : Nat, i.val.toNat ≤ k → m3.val[k]? = mark.val[k]?) ∧
              (0 ≤ a.val → a.val.toNat < i.val.toNat → m3.val[a.val.toNat]? = some true) := by
            split at hm3
            · rename_i hcond
              simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val] at hcond
              obtain ⟨m4, hm4, hm3⟩ := bind_eq_ok hm3
              cases ok_inj' hm3
              have hm4' := arr_set_ok hm4
              have hal : a.val.toNat < mark.val.length := by rw [hl]; omega
              exact ⟨by rw [hm4']; simp, fun j hj => by rw [hm4']; exact set_true_mono hj,
                fun k hk => by rw [hm4']; exact getElem?_set_ne' (by omega) _,
                fun _ _ => by rw [hm4']; exact getElem?_set_true_self hal⟩
            · rename_i hcond
              simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val,
                not_and, not_lt] at hcond
              cases ok_inj' hm3
              exact ⟨rfl, fun j hj => hj, fun k hk => rfl, fun h1 h2 => absurd (hcond h1) (by omega)⟩
          obtain ⟨c3l, c3m, c3k, c3a⟩ := c3
          split at hm1
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val] at hcond
            obtain ⟨m5, hm5, hm1⟩ := bind_eq_ok hm1
            cases ok_inj' hm1
            have hm5' := arr_set_ok hm5
            have hbl : b.val.toNat < m3.val.length := by rw [c3l, hl]; omega
            refine ⟨by rw [hm5']; simp [c3l], fun j hj => by rw [hm5']; exact set_true_mono (c3m j hj),
              fun k hk => by rw [hm5', getElem?_set_ne' (by omega) _]; exact c3k k hk, fun _ n hn => ?_⟩
            rw [hnode] at hn; cases hn
            exact ⟨fun h1 h2 => by rw [hm5']; exact set_true_mono (c3a h1 h2),
              fun _ _ => by rw [hm5']; exact getElem?_set_true_self hbl⟩
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val,
              not_and, not_lt] at hcond
            cases ok_inj' hm1
            refine ⟨c3l, c3m, c3k, fun _ n hn => ?_⟩
            rw [hnode] at hn; cases hn
            exact ⟨c3a, fun h1 h2 => absurd (hcond h1) (by omega)⟩
        all_goals
          simp only at hm1
          cases ok_inj' hm1
          refine ⟨rfl, fun j hj => hj, fun k hk => rfl, fun _ n hn => ?_⟩
          rw [hnode] at hn; cases hn; trivial
      · rename_i htf
        cases ok_inj' hm1
        exact ⟨rfl, fun j hj => hj, fun k hk => rfl, fun e => absurd e htf⟩
    obtain ⟨cl, cm, ck, cc⟩ := claim
    refine ⟨by omega, by omega, by rw [cl, hl], cm _ hmv, fun k hk1 hk2 hk3 => ?_⟩
    by_cases hki : k = i.val.toNat
    · subst hki
      cases t5 with
      | true => exact cc rfl
      | false =>
        rw [ck _ (le_refl _), List.getElem?_eq_getElem ht5l, ht5v] at hk3
        cases hk3
    · have hk' : i.val < k := by omega
      rw [ck k (by omega)] at hk3
      exact childMarked_mono cm (hcm k hk' hk2 hk3)
  · rename_i hlt
    have hi : i.val < 0 := by simpa [i32_le_iff] using hlt
    rw [← ok_inj' hc]
    exact ⟨hl, hmv, fun k hk hk3 => hcm k (by omega) hk hk3⟩

/-- Every marked node below `j` has a memo entry with the node's value under the facts. -/
def MemoOK (vg vgj : ValGraph) (fs : List Fact) (mark : List Bool) (memo : List Std.I32) (j : Nat) :
    Prop :=
  ∀ k : Nat, k < j → mark[k]? = some true → ∃ m, memo[k]? = some m ∧ Valid vgj m ∧
    ∀ G env, vg_extends vgj G → FactsHold G env fs → evI vgj env m = evalSym vg env k

theorem evalSym_at {vg : ValGraph} {j : Nat} {n : SymNode} (h : vg.nodes.val[j]? = some n)
    (env : SymEnv) : evalSym vg env j = evalNode env
      (fun a => if 0 ≤ a.val ∧ a.val.toNat < j then evalSym vg env a.val.toNat else 0) n := by
  rw [evalSym_unfold, h]
  simp only [dite_eq_ite]

theorem i32_toNat_val {k : Nat} (hk : k < 2147483648) :
    (⟨BitVec.ofNat 32 k⟩ : Std.I32).val.toNat = k := by
  have := i32_ofNat_val k hk
  rw [this]; simp

theorem apply_loop1 {vg : ValGraph} {fs : Pion.Array Fact} {mark : Pion.Array Bool} {n0 : Std.I32}
    (_hd : ValGraphDAG vg) (hn0 : n0.val ≤ vg.nodes.val.length)
    (hmark : ∀ k : Nat, k < n0.val.toNat → mark.val[k]? = some true → ChildMarked vg mark.val k) :
    ∀ (x : Std.I32 × ValGraph × Pion.Array Std.I32) r,
      apply_facts_loop1 n0 mark fs x.1 x.2.1 x.2.2 = ok r →
      (0 ≤ x.1.val ∧ vg_extends vg x.2.1 ∧ ValGraphDAG x.2.1 ∧ x.2.2.val.length = n0.val.toNat ∧
        MemoOK vg x.2.1 fs.val mark.val x.2.2.val x.1.val.toNat) →
      vg_extends vg r.2.1 ∧ ValGraphDAG r.2.1 ∧ MemoOK vg r.2.1 fs.val mark.val r.2.2.val n0.val.toNat := by
  intro x r h hx
  unfold apply_facts_loop1 at h
  refine loop_ok_inv (fun (x : Std.I32 × ValGraph × Pion.Array Std.I32) =>
      match x with | (j, vg, memo) => apply_facts_loop1.body n0 mark fs j vg memo)
    (fun (x : Std.I32 × ValGraph × Pion.Array Std.I32) =>
      0 ≤ x.1.val ∧ vg_extends vg x.2.1 ∧ ValGraphDAG x.2.1 ∧ x.2.2.val.length = n0.val.toNat ∧
        MemoOK vg x.2.1 fs.val mark.val x.2.2.val x.1.val.toNat)
    (fun (r : Std.I32 × ValGraph × Pion.Array Std.I32) =>
      vg_extends vg r.2.1 ∧ ValGraphDAG r.2.1 ∧ MemoOK vg r.2.1 fs.val mark.val r.2.2.val n0.val.toNat)
    ?_ x r h hx
  rintro ⟨j, vgj, memo⟩ c ⟨hj0, hej, hdj, hml, hmemo⟩ hc
  simp only at hj0 hej hdj hml hmemo hc
  unfold apply_facts_loop1.body at hc
  split at hc
  · rename_i hlt
    have hlt' : j.val < n0.val := hlt
    have hjl : j.val.toNat < vg.nodes.val.length := by omega
    have hjs := i32_succ_val hlt
    obtain ⟨t13, ht13, hc⟩ := bind_eq_ok hc
    obtain ⟨_, ht13l, ht13v⟩ := arr_get_ok ht13
    obtain ⟨q, hq, hc⟩ := bind_eq_ok hc
    obtain ⟨vg1, memo1⟩ := q
    rw [← ok_inj' hc]
    dsimp only
    split at hq
    · rename_i htt
      have hjlj : j.val.toNat < vgj.nodes.val.length := lt_of_lt_of_le hjl (prefix_length hej)
      rw [arr_get_eq vgj.nodes j hj0 (by omega), bind_ok] at hq
      generalize hnv : vgj.nodes.val[j.val.toNat]'(by omega) = n at hq
      have hnode : vg.nodes.val[j.val.toNat]? = some n := by
        rw [← prefix_getElem? hej hjl, List.getElem?_eq_getElem hjlj, hnv]
      have hmj : mark.val[j.val.toNat]? = some true := by
        rw [List.getElem?_eq_getElem ht13l, ht13v, htt]
      obtain ⟨q2, hq2, hq⟩ := bind_eq_ok hq
      have hstep : vg_extends vgj q2.2 ∧ ValGraphDAG q2.2 ∧ Valid q2.2 q2.1 ∧
          ∀ G env, vg_extends q2.2 G → FactsHold G env fs.val → evI q2.2 env q2.1 = evalSym vg env j.val.toNat := by
        have hj := hej
        have hcm := hmark _ (by omega) hmj
        have h := hq2
        have hn := hnode
        clear hq2
        have hjv : Valid vgj j := extends_valid hj ⟨hj0, hjl⟩
        have hid : q2 = (j, vgj) → vg_extends vgj q2.2 ∧ ValGraphDAG q2.2 ∧ Valid q2.2 q2.1 ∧
            ∀ G env, vg_extends q2.2 G → FactsHold G env fs.val → evI q2.2 env q2.1 = evalSym vg env j.val.toNat := by
          rintro rfl
          exact ⟨vg_extends_refl _, hdj, hjv, fun G env _ _ => extends_evI hj env ⟨hj0, hjl⟩⟩
        have hval := evalSym_at hn
        -- the memo entry of a marked child
        have hchild : ∀ a : Std.I32, 0 ≤ a.val → a.val < j.val → mark.val[a.val.toNat]? = some true →
            ∃ m, memo.get a = ok m ∧ Valid vgj m ∧
              ∀ G env, vg_extends vgj G → FactsHold G env fs.val → evI vgj env m = evalSym vg env a.val.toNat := by
          intro a ha0 haj hma
          obtain ⟨m, hm, hmv, hmval⟩ := hmemo a.val.toNat (by omega) hma
          have hal : a.val.toNat < memo.val.length := by
            by_contra hc; rw [List.getElem?_eq_none (by omega)] at hm; cases hm
          refine ⟨m, ?_, hmv, hmval⟩
          rw [arr_get_eq memo a ha0 (by omega)]
          rw [List.getElem?_eq_getElem hal] at hm
          cases hm; rfl
        cases n
        case SUn c op a =>
          try simp only at h
          split at h
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val] at hcond
            have hma := (hcm _ hn) hcond.1 (by omega)
            obtain ⟨m, hm, hmv, hmval⟩ := hchild a hcond.1 hcond.2 hma
            simp only [unop_arg_cls_spec, hm, bind_ok] at h
            obtain ⟨q, hq, h⟩ := bind_eq_ok h
            obtain ⟨ua, vg3⟩ := q
            try simp only [uncurry_apply_pair] at h
            have h3 := vg_use_sound hq hdj hmv
            obtain ⟨e3, d3, v3, c3, val3⟩ := h3
            dsimp only at e3 d3 v3 c3 val3
            have h4 := vg_canon_un_sound vg3 c op d3 ua q2 (pair_ok h) v3
              ⟨fun e => by subst e; simpa [unArgCls] using c3,
                fun _ e => by rcases e with rfl | rfl <;> simpa [unArgCls] using c3⟩
            obtain ⟨e4, d4, v4, -, val4⟩ := h4
            refine ⟨vg_extends_trans e3 e4, d4, v4, fun G env hG hf => ?_⟩
            rw [val4 env]; dsimp only
            rw [val3 env, evalUn_argmask, hmval G env (vg_extends_trans (vg_extends_trans e3 e4) hG) hf, hval env]
            simp only [evalNode]
            rw [ite_eq_left ⟨hcond.1, by omega⟩]
          · exact hid (ok_inj' h).symm
        case SBin c op a b =>
          try simp only at h
          split at h
          · rename_i hcond
            simp only [Bool.and_eq_true, decide_eq_true_eq, i32_le_iff, i32_lt_iff, i32_zero_val] at hcond
            obtain ⟨⟨⟨ha0, haj⟩, hb0⟩, hbj⟩ := hcond
            have hcmn := hcm _ hn
            obtain ⟨ma, hma, hmav, hmaval⟩ := hchild a ha0 haj (hcmn.1 ha0 (by omega))
            obtain ⟨mb, hmb, hmbv, hmbval⟩ := hchild b hb0 hbj (hcmn.2 hb0 (by omega))
            simp only [binop_arg_cls_spec0, binop_arg_cls_spec1, hma, hmb, is_trapping_binop_spec,
              bind_ok] at h
            obtain ⟨q5, hq5, h⟩ := bind_eq_ok h
            obtain ⟨ua, vg5⟩ := q5
            try simp only [uncurry_apply_pair] at h
            obtain ⟨q6, hq6, h⟩ := bind_eq_ok h
            obtain ⟨ub, vg6⟩ := q6
            try simp only [uncurry_apply_pair] at h
            obtain ⟨e5, d5, v5, c5, val5⟩ := vg_use_sound hq5 hdj hmav
            obtain ⟨e6, d6, v6, c6, val6⟩ := vg_use_sound hq6 d5 (extends_valid e5 hmbv)
            dsimp only at e5 d5 v5 c5 val5 e6 d6 v6 c6 val6
            have hA : ∀ G env, vg_extends vg6 G → FactsHold G env fs.val →
                evI vg6 env ua = maskC (binArgCls op c 0) (evalSym vg env a.val.toNat) := by
              intro G env hG hf
              rw [extends_evI e6 env v5, val5 env, hmaval G env (vg_extends_trans (vg_extends_trans e5 e6) hG) hf]
            have hB : ∀ G env, vg_extends vg6 G → FactsHold G env fs.val →
                evI vg6 env ub = maskC (binArgCls op c 1) (evalSym vg env b.val.toNat) := by
              intro G env hG hf
              rw [val6 env, extends_evI e5 env hmbv, hmbval G env (vg_extends_trans (vg_extends_trans e5 e6) hG) hf]
            have hnode : ∀ env, evalSym vg env j.val.toNat =
                (evalBin c op (evalSym vg env a.val.toNat) (evalSym vg env b.val.toNat)).getD 0 := by
              intro env
              rw [hval env]
              simp only [evalNode]
              rw [ite_eq_left ⟨ha0, by omega⟩, ite_eq_left ⟨hb0, by omega⟩]
            obtain ⟨t33, ht33, h⟩ := bind_eq_ok h
            split at h
            · -- a division that may trap keeps its operation
              rename_i h33
              obtain ⟨q7, hq7, h⟩ := bind_eq_ok h
              cases ok_inj' h
              have hc7 : childrenBelow (SymNode.SBin c op ma mb) vg6.nodes.val.length :=
                ⟨extends_valid (vg_extends_trans e5 e6) hmav, extends_valid e6 (extends_valid e5 hmbv)⟩
              obtain ⟨e7, d7, nd7, -, val7⟩ := vg_intern_spec hq7 d6 hc7
              refine ⟨vg_extends_trans e5 (vg_extends_trans e6 e7), d7, nodeAt_valid nd7, fun G env hG hf => ?_⟩
              have hGj : vg_extends vgj G := vg_extends_trans (vg_extends_trans e5 (vg_extends_trans e6 e7)) hG
              rw [val7 env, hnode env]
              simp only [evalNode]
              rw [extends_evI (vg_extends_trans e5 e6) env hmav, extends_evI e6 env (extends_valid e5 hmbv),
                extends_evI e5 env hmbv, hmaval G env hGj hf, hmbval G env hGj hf]
            · rename_i h33
              have hsafe : ∀ env, evalBin c op (evI vg6 env ua) (evI vg6 env ub) ≠ none := by
                intro env
                cases htr : trapOp op
                · exact evalBin_some_of_not_trap htr c _ _
                · rw [htr] at ht33
                  simp only [↓reduceIte] at ht33
                  obtain ⟨t32, ht32, ht33⟩ := bind_eq_ok ht33
                  cases ok_inj' ht33
                  have : t32 = true := by cases t32 <;> simp_all
                  subst this
                  exact bin_safe_sound ht32 d6 env
              have c5' : clsOf vg6 ua = binArgCls op c 0 := by rw [extends_clsOf e6 v5]; exact c5
              have hok : BinArgOK vg6 c op ua ub := by
                unfold BinArgOK
                cases op <;> simp [isCmp, isShift, binArgCls] at c5' c6 ⊢ <;>
                  first | exact ⟨c5', c6⟩ | exact c5'
              obtain ⟨e8, d8, v8, -, val8⟩ := vg_canon_bin_sound (pair_ok h) d6 (extends_valid e6 v5) v6 hok
              refine ⟨vg_extends_trans e5 (vg_extends_trans e6 e8), d8, v8, fun G env hG hf => ?_⟩
              obtain ⟨w, hw⟩ := Option.ne_none_iff_exists'.1 (hsafe env)
              rw [val8 env w hw, hnode env]
              rw [hA G env (vg_extends_trans e8 hG) hf, hB G env (vg_extends_trans e8 hG) hf, evalBin_argmask] at hw
              rw [hw]; rfl
          · exact hid (ok_inj' h).symm
        all_goals (try simp only at h); exact hid (ok_inj' h).symm
      obtain ⟨r, vg2⟩ := q2
      obtain ⟨e2, d2, v2, val2⟩ := hstep
      dsimp only at e2 d2 v2 val2
      try simp only [uncurry_apply_pair] at hq
      obtain ⟨q9, hq9, hq⟩ := bind_eq_ok hq
      obtain ⟨t44, vg9⟩ := q9
      try simp only [uncurry_apply_pair] at hq
      obtain ⟨memo2, hm2, hq⟩ := bind_eq_ok hq
      cases ok_inj' hq
      obtain ⟨e9, d9, v9, val9⟩ := fact_post_sound hq9 d2 v2
      dsimp only at e9 d9 v9 val9
      have hm2' := arr_set_ok hm2
      refine ⟨by omega, vg_extends_trans hej (vg_extends_trans e2 e9), d9,
        by rw [hm2', List.length_set, hml], ?_⟩
      intro k hk hmk
      by_cases hkj : k = j.val.toNat
      · subst hkj
        refine ⟨t44, by rw [hm2']; simp [hml, show j.val.toNat < n0.val.toNat by omega], v9,
          fun G env hG hf => ?_⟩
        rw [val9 G env hG hf, val2 G env (vg_extends_trans e9 hG) hf]
      · obtain ⟨m, hm, hmv, hmval⟩ := hmemo k (by omega) hmk
        refine ⟨m, by rw [hm2', List.getElem?_set_ne (Ne.symm hkj)]; exact hm,
          extends_valid (vg_extends_trans e2 e9) hmv, fun G env hG hf => ?_⟩
        rw [extends_evI (vg_extends_trans e2 e9) env hmv, hmval G env (vg_extends_trans (vg_extends_trans e2 e9) hG) hf]
    · rename_i htf
      cases ok_inj' hq
      refine ⟨by omega, hej, hdj, hml, fun k hk hmk => ?_⟩
      by_cases hkj : k = j.val.toNat
      · subst hkj
        rw [List.getElem?_eq_getElem ht13l, ht13v] at hmk
        cases hmk
        exact absurd rfl htf
      · exact hmemo k (by omega) hmk
  · rename_i hge
    have hge' : n0.val ≤ j.val := by simpa [i32_lt_iff] using hge
    rw [← ok_inj' hc]
    exact ⟨hej, hdj, fun k hk hmk => hmemo k (by omega) hmk⟩

/-- `apply_facts vg fs v` is a node with the value of `v` wherever the facts `fs` hold. -/
theorem apply_facts_sound {vg : ValGraph} {fs : Pion.Array Fact} {v : Std.I32} {p : Std.I32 × ValGraph}
    (h : apply_facts vg fs v = ok p) (hd : ValGraphDAG vg) :
    vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧
      (Valid vg v → Valid p.2 p.1 ∧ ∀ G env, vg_extends p.2 G → FactsHold G env fs.val →
        evI p.2 env p.1 = evI vg env v) ∧
      (¬ Valid vg v → p = (v, vg)) := by
  unfold apply_facts at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, ht2⟩ := vg_valid_ok ht
  obtain ⟨t2, ht2', h⟩ := bind_eq_ok h
  cases t2
  case true =>
    simp only [↓reduceIte] at h
    cases ok_inj' h
    exact ⟨vg_extends_refl _, hd, fun hv => ⟨hv, fun _ _ _ _ => rfl⟩, fun _ => rfl⟩
  simp only [Bool.false_eq_true, ↓reduceIte] at h
  have htt : t = true := by
    cases t
    · simp only [Bool.not_false, ↓reduceIte] at ht2'; cases ok_inj' ht2'
    · rfl
  have hv := ht1.1 htt
  have hl := ht2 htt
  clear ht2' ht1 ht2 ht
  have hv0 := hv.1
  have hvl := hv.2
  have hvs := i32_succ_val' (m := vg.nodes.val.length) (i := v) (by have := hv.2; omega) hl
  obtain ⟨mark1, hm1, h⟩ := bind_eq_ok h
  have hm1' := arr_set_ok hm1
  have hn0 : (Pion.I32.add v 1#i32).val.toNat = v.val.toNat + 1 := by omega
  obtain ⟨q0, hq0, h⟩ := bind_eq_ok h
  obtain ⟨i1, mark2⟩ := q0
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
  obtain ⟨j1, vg1, memo1⟩ := q1
  try simp only [uncurry_apply_pair] at h
  obtain ⟨t46, ht46, h⟩ := bind_eq_ok h
  cases ok_inj' h
  have hml1 : mark1.val.length = v.val.toNat + 1 := by
    rw [hm1']; simp only [Pion.Array.make, listMake, List.length_set, List.length_replicate]; omega
  have hmv1 : mark1.val[v.val.toNat]? = some true := by
    rw [hm1']; simp only [Pion.Array.make, listMake]
    rw [List.getElem?_set_self (by simp only [List.length_replicate]; omega)]
  obtain ⟨hml2, hmv2, hcm2⟩ := mark_loop hv (v, mark1) _ hq0
    ⟨by dsimp only; omega, le_refl _, hml1, hmv1, fun k hk1 hk2 => by dsimp only at hk1; omega⟩
  dsimp only at hml2 hmv2 hcm2
  obtain ⟨e1, d1, hmemo⟩ := apply_loop1 (mark := mark2) hd (by omega)
    (fun k hk hmk => hcm2 k (by omega) hmk) (0#i32, vg, ⟨listMake (Pion.I32.add v 1#i32) (-1)#i32⟩) _ hq1
    ⟨by simp, vg_extends_refl _, hd, by simp only [listMake, List.length_replicate],
      fun k hk => by simp at hk⟩
  dsimp only at e1 d1 hmemo
  obtain ⟨m, hm, hmv, hmval⟩ := hmemo v.val.toNat (by omega) hmv2
  obtain ⟨_, h46l, h46v⟩ := arr_get_ok ht46
  have : t46 = m := by
    rw [List.getElem?_eq_getElem h46l, h46v] at hm; cases hm; rfl
  subst this
  exact ⟨e1, d1, fun _ => ⟨hmv, fun G env hG hf => by rw [hmval G env hG hf]⟩, fun hn => absurd hv hn⟩

theorem apply_facts_ext {vg : ValGraph} {fs : Pion.Array Fact} {v : Std.I32} {p : Std.I32 × ValGraph}
    (h : apply_facts vg fs v = ok p) (hd : ValGraphDAG vg) : vg_extends vg p.2 ∧ ValGraphDAG p.2 :=
  ⟨(apply_facts_sound h hd).1, (apply_facts_sound h hd).2.1⟩

/-- `eq_under vg fs x y` may only grow the graph. -/
theorem eq_under_ext {vg : ValGraph} {fs : Pion.Array Fact} {x y : Std.I32} {p : Bool × ValGraph}
    (h : eq_under vg fs x y = ok p) (hd : ValGraphDAG vg) : vg_extends vg p.2 ∧ ValGraphDAG p.2 := by
  unfold eq_under at h
  obtain ⟨t, -, h⟩ := bind_eq_ok h
  obtain ⟨t2, -, h⟩ := bind_eq_ok h
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd⟩
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd⟩
  obtain ⟨t3, -, h⟩ := bind_eq_ok h
  split at h
  · cases ok_inj' h; exact ⟨vg_extends_refl _, hd⟩
  obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
  obtain ⟨x1, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
  obtain ⟨y1, vg2⟩ := q2
  cases ok_inj' h
  obtain ⟨e1, d1⟩ := apply_facts_ext hq1 hd
  obtain ⟨e2, d2⟩ := apply_facts_ext hq2 d1
  exact ⟨vg_extends_trans e1 e2, d2⟩

/-- `eq_under vg fs x y`: `x` and `y` are equal wherever the facts `fs` hold. -/
theorem eq_under_sound {vg : ValGraph} {fs : Pion.Array Fact} {x y : Std.I32} {vg' : ValGraph}
    (h : eq_under vg fs x y = ok (true, vg')) (hd : ValGraphDAG vg) :
    vg_extends vg vg' ∧ ValGraphDAG vg' ∧ Valid vg x ∧ Valid vg y ∧
      ∀ G env, vg_extends vg' G → FactsHold G env fs.val → evI vg env x = evI vg env y := by
  have hext := eq_under_ext h hd
  unfold eq_under at h
  obtain ⟨t, ht, h⟩ := bind_eq_ok h
  obtain ⟨ht1, -⟩ := vg_valid_ok ht
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  split at h
  · cases ok_inj' h
  rename_i h2f
  have hvx : Valid vg x := by
    cases t
    · cases ok_inj' ht2; exact absurd rfl h2f
    · exact ht1.1 rfl
  have hvy : Valid vg y := by
    cases t
    · cases ok_inj' ht2; exact absurd rfl h2f
    · simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at ht2
      obtain ⟨t1, ht1', ht2⟩ := bind_eq_ok ht2
      cases ok_inj' ht2
      cases t1
      · exact absurd rfl h2f
      · exact (vg_valid_ok ht1').1.1 rfl
  refine ⟨hext.1, hext.2, hvx, hvy, ?_⟩
  split at h
  · rename_i hxy; subst hxy; exact fun _ _ _ _ => rfl
  obtain ⟨t3, -, h⟩ := bind_eq_ok h
  split at h
  · cases ok_inj' h
  obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
  obtain ⟨x1, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
  obtain ⟨y1, vg2⟩ := q2
  have heq := ok_inj' h
  simp only [Prod.mk.injEq, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at heq
  obtain ⟨⟨-, hxy⟩, hvg⟩ := heq
  subst hxy
  obtain ⟨e1, d1, hx1, -⟩ := apply_facts_sound hq1 hd
  obtain ⟨hx1v, hx1e⟩ := hx1 hvx
  dsimp only at e1 d1 hx1v hx1e
  obtain ⟨e2, d2, hy1, -⟩ := apply_facts_sound hq2 d1
  obtain ⟨hy1v, hy1e⟩ := hy1 (extends_valid e1 hvy)
  dsimp only at e2 d2 hy1v hy1e
  intro G env hG hf
  rw [← hvg] at hG
  have h1 := hx1e G env (vg_extends_trans e2 hG) hf
  have h2 := hy1e G env hG hf
  rw [extends_evI e1 env hvy] at h2
  rw [← h1, ← h2, extends_evI e2 env hx1v]

/-! ## Atoms -/

/-- Every entry of `vids` is `-1` or a node of `vg` (`vids_ok`). -/
def VidsOK (vg : ValGraph) (vids : List Std.I32) : Prop :=
  ∀ (t : Nat) (v : Std.I32), vids[t]? = some v → v = (-1)#i32 ∨ Valid vg v

theorem vidsOK_extends {vg vg' : ValGraph} (hp : vg_extends vg vg') {vids : List Std.I32}
    (h : VidsOK vg vids) : VidsOK vg' vids := fun t v hv =>
  (h t v hv).elim Or.inl (fun hv' => Or.inr (extends_valid hp hv'))

/-- The raw word of an atom in the value graph (`vids` give the temps' values). -/
def atomSem (vg : ValGraph) (env : SymEnv) (vids : List Std.I32) : Atom → BitVec 64
  | .Temp t => if 0 ≤ t.val then (match vids[t.val.toNat]? with
      | some v => evI vg env v
      | none => 0) else 0
  | .Const v => v.bv
  | .Sym s off => env.symAddr s + off.bv

theorem vg_use_invalid {vg : ValGraph} {cls : Cls} {v : Std.I32} {p : Std.I32 × ValGraph}
    (h : vg_use vg cls v = ok p) (hv : ¬ Valid vg v) : p = ((-1)#i32, vg) := by
  unfold vg_use at h
  obtain ⟨b, hb, h⟩ := bind_eq_ok h
  obtain ⟨hb1, -⟩ := vg_valid_ok hb
  have : b = false := by
    cases b
    · rfl
    · exact absurd (hb1.1 rfl) hv
  subst this
  exact (ok_inj' h).symm

theorem m1_neg : ((-1)#i32 : Std.I32).val < 0 := by decide

/-- `atom_use vg vids cls a`: `a` read at class `cls`, or `-1` for a temp without value. -/
theorem atom_use_sound {vg : ValGraph} {vids : Pion.Array Std.I32} {cls : Cls} {a : Atom}
    {p : Std.I32 × ValGraph} (h : atom_use vg vids cls a = ok p) (hd : ValGraphDAG vg)
    (_hv : VidsOK vg vids.val) :
    vg_extends vg p.2 ∧ ValGraphDAG p.2 ∧
      (0 ≤ p.1.val → Valid p.2 p.1 ∧ clsOf p.2 p.1 = cls ∧
        (∀ t, a = .Temp t → 0 ≤ t.val ∧ ∃ v, vids.val[t.val.toNat]? = some v ∧ Valid vg v) ∧
        ∀ env, evI p.2 env p.1 = maskC cls (atomSem vg env vids.val a)) := by
  unfold atom_use at h
  cases a with
  | Temp t =>
    simp only at h
    obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
    split at h
    · rename_i htt
      have ht : 0 ≤ t.val ∧ t.val < vids.val.length := by
        split at ht2
        · rename_i hge
          obtain ⟨n, hn, ht2⟩ := bind_eq_ok ht2
          obtain ⟨hn1, -⟩ := arr_length_ok hn
          cases ok_inj' ht2
          simp only [decide_eq_true_eq, i32_lt_iff] at htt
          exact ⟨by simpa [i32_le_iff] using hge, by omega⟩
        · cases ok_inj' ht2; cases htt
      obtain ⟨v, hgv, h⟩ := bind_eq_ok h
      obtain ⟨_, hvl, hvv⟩ := arr_get_ok hgv
      have hvt : vids.val[t.val.toNat]? = some v := by rw [List.getElem?_eq_getElem hvl, hvv]
      have hu := pair_ok h
      by_cases hval : Valid vg v
      · obtain ⟨e, d, vv, c, val⟩ := vg_use_sound hu hd hval
        refine ⟨e, d, fun _ => ⟨vv, c, fun t' e' => ?_, fun env => ?_⟩⟩
        · cases e'; exact ⟨ht.1, v, hvt, hval⟩
        · rw [val env]; simp only [atomSem, ht.1, ↓reduceIte, hvt]
      · rw [vg_use_invalid hu hval]
        exact ⟨vg_extends_refl _, hd, fun hc => absurd hc (by simp only; exact not_le.2 m1_neg)⟩
    · cases ok_inj' h
      exact ⟨vg_extends_refl _, hd, fun hc => absurd hc (by simp only; exact not_le.2 m1_neg)⟩
  | Const x =>
    simp only at h
    obtain ⟨e, d, vv, c, -, val⟩ := konst_facts hd (pair_ok h)
    exact ⟨e, d, fun _ => ⟨vv, c, fun t e' => (by cases e'), fun env => by rw [val env]; rfl⟩⟩
  | Sym id off =>
    simp only at h
    obtain ⟨q, hq, h⟩ := bind_eq_ok h
    obtain ⟨sv, vg3⟩ := q
    obtain ⟨e3, d3, n3, -, val3⟩ := vg_intern_spec hq hd trivial
    have hsv : Valid vg3 sv := nodeAt_valid n3
    have hsc : clsOf vg3 sv = .L := by rw [clsOf_node n3]; rfl
    have hsval : ∀ env, evI vg3 env sv = env.symAddr id := fun env => by rw [val3 env]; rfl
    try simp only [uncurry_apply_pair] at h
    obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
    obtain ⟨r, vg4⟩ := q2
    -- the address before the class read
    have hr : vg_extends vg3 vg4 ∧ ValGraphDAG vg4 ∧ Valid vg4 r ∧
        ∀ env, evI vg4 env r = env.symAddr id + off.bv := by
      split at hq2
      · rename_i h0
        cases ok_inj' hq2
        refine ⟨vg_extends_refl _, d3, hsv, fun env => ?_⟩
        rw [hsval env, h0]; simp
      · obtain ⟨q5, hq5, hq2⟩ := bind_eq_ok hq2
        obtain ⟨o, vg5⟩ := q5
        obtain ⟨e5, d5, vo, co, -, valo⟩ := konst_facts d3 hq5
        try simp only [uncurry_apply_pair] at hq2
        obtain ⟨e6, d6, v6, -, val6⟩ := vg_canon_bin_sound (pair_ok hq2) d5 (extends_valid e5 hsv) vo
          (by unfold BinArgOK; simp only [isCmp, isShift, Bool.false_eq_true, ↓reduceIte]
              exact ⟨by rw [extends_clsOf e5 hsv, hsc], co⟩)
        refine ⟨vg_extends_trans e5 e6, d6, v6, fun env => ?_⟩
        apply val6 env
        rw [extends_evI e5 env hsv, hsval env, valo env]
        simp [evalBin, maskC]
    obtain ⟨e4, d4, v4, val4⟩ := hr
    obtain ⟨e7, d7, v7, c7, val7⟩ := vg_use_sound (pair_ok h) d4 v4
    refine ⟨vg_extends_trans e3 (vg_extends_trans e4 e7), d7, fun _ => ⟨v7, c7, fun t e' => (by cases e'),
      fun env => ?_⟩⟩
    rw [val7 env]; dsimp only; rw [val4 env]; rfl

/-- The registers of a run agree with `vids` on the temps of `dom`. -/
def RegsAgree (vg : ValGraph) (env : SymEnv) (dom : Nat → Prop) (vids : List Std.I32)
    (regs : Nat → BitVec 64) : Prop :=
  ∀ t, dom t → ∀ v, vids[t]? = some v → Valid vg v → regs t = evI vg env v

/-- The temp of an atom, if any, agrees with `vids`. -/
def AtomAgree {W : Type} (vg : ValGraph) (env : SymEnv) (vids : List Std.I32) (o : WorldOracle W)
    (regs : Nat → BitVec 64) (a : Atom) : Prop :=
  env.symAddr = o.symAddr ∧
    ∀ t, a = .Temp t → ∀ v, vids[t.val.toNat]? = some v → Valid vg v → regs t.val.toNat = evI vg env v

/-- A known `atom_use` value is the value the run reads. -/
theorem atom_use_val {W : Type} {vg : ValGraph} {vids : Pion.Array Std.I32} {cls : Cls} {a : Atom}
    {p : Std.I32 × ValGraph} (h : atom_use vg vids cls a = ok p) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val) (hp : 0 ≤ p.1.val) {env : SymEnv} {o : WorldOracle W}
    {regs : Nat → BitVec 64} (hag : AtomAgree vg env vids.val o regs a) :
    evI p.2 env p.1 = atomVal o regs cls a := by
  obtain ⟨-, -, hs⟩ := atom_use_sound h hd hv
  obtain ⟨-, -, ht, hval⟩ := hs hp
  rw [hval env]
  unfold atomVal atomRaw
  congr 1
  cases a with
  | Temp t =>
    obtain ⟨ht0, v, hvt, hvv⟩ := ht t rfl
    simp only [atomSem, ht0, ↓reduceIte, hvt]
    exact (hag.2 t rfl v hvt hvv).symm
  | Const x => rfl
  | Sym s off => simp only [atomSem, hag.1]

/-! ## Edge facts -/

/-- The run left a block with terminator `t` towards `s`. -/
def EdgeTaken {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (t : Term) (s : Std.I32) : Prop :=
  match t with
  | .Jmp d => s = d
  | .Jnz c s1 s2 => s = (if atomVal o regs .W c ≠ 0 then s1 else s2)
  | _ => False

/-- The condition of a `jnz` terminator agrees with `vids`. -/
def CondAgree {W : Type} (vg : ValGraph) (env : SymEnv) (vids : List Std.I32) (o : WorldOracle W)
    (regs : Nat → BitVec 64) (t : Term) : Prop :=
  match t with
  | .Jnz c _ _ => AtomAgree vg env vids o regs c
  | _ => True

theorem condAgree_extends {W : Type} {vg vg' : ValGraph} (hp : vg_extends vg vg') {env : SymEnv}
    {vids : List Std.I32} {o : WorldOracle W} {regs : Nat → BitVec 64} {t : Term}
    (hv : VidsOK vg vids) (h : CondAgree vg env vids o regs t) : CondAgree vg' env vids o regs t := by
  cases t with
  | Jnz c s1 s2 =>
    refine ⟨h.1, fun t' e v hvt hvv => ?_⟩
    rcases hv _ v hvt with rfl | hvv'
    · exact absurd hvv (by intro hc; exact absurd hc.1 (by decide))
    · rw [h.2 t' e v hvt hvv', extends_evI hp env hvv']
  | _ => trivial

/-- `edge_facts vg f vids p s`: the facts the edge `p -> s` establishes hold on every run
taking it. -/
theorem edge_facts_sound {vg : ValGraph} {f : Func} {vids : Pion.Array Std.I32} {p s : Std.I32}
    {q : Pion.Array Fact × ValGraph} (h : edge_facts vg f vids p s = ok q) (hd : ValGraphDAG vg)
    (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (∀ fa ∈ q.1.val, fa.blk = s) ∧
      ∀ (B : Block), 0 ≤ p.val → f.blocks.val[p.val.toNat]? = some B →
        ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
          CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s →
          FactsHold q.2 env q.1.val := by
  unfold edge_facts at h
  obtain ⟨B0, hB0, h⟩ := bind_eq_ok h
  obtain ⟨hp0, hpl, hpv⟩ := arr_get_ok hB0
  have hBeq : ∀ B : Block, f.blocks.val[p.val.toNat]? = some B → B = B0 := by
    intro B hB; rw [List.getElem?_eq_getElem hpl, hpv] at hB; cases hB; rfl
  have hnil : ∀ (vg1 : ValGraph), vg_extends vg vg1 → ValGraphDAG vg1 →
      q = (Pion.Array.ofList [], vg1) → vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (∀ fa ∈ q.1.val, fa.blk = s) ∧
      ∀ (B : Block), 0 ≤ p.val → f.blocks.val[p.val.toNat]? = some B →
        ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
          CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s → FactsHold q.2 env q.1.val := by
    rintro vg1 e1 d1 rfl
    exact ⟨e1, d1, fun fa hfa => by simp at hfa, fun _ _ _ _ _ _ _ _ _ fa hfa => by simp at hfa⟩
  try simp only at h
  generalize hT : B0.term = T at h
  cases T with
  | Jnz c s1 s2 =>
    try simp only at h
    split at h
    · rename_i hcond
      simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, Bool.or_eq_true, beq_iff_eq] at hcond
      obtain ⟨hne, hs⟩ := hcond
      obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
      obtain ⟨cv, vg1⟩ := q1
      obtain ⟨e1, d1, hcv⟩ := atom_use_sound hq1 hd hv
      dsimp only at e1 d1 hcv
      simp only [uncurry_apply_pair] at h
      split at h
      · rename_i hcv0
        have hcv0' : 0 ≤ cv.val := by simpa [i32_le_iff] using hcv0
        obtain ⟨vcv, ccv, htc, valcv⟩ := hcv hcv0'
        -- the value of the condition on the run
        have hrun : ∀ (B : Block), f.blocks.val[p.val.toNat]? = some B →
            ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
              CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s →
              (evI vg1 env cv ≠ 0 ↔ s = s1) := by
          intro B hB W o regs env hca het
          have e := hBeq B hB
          subst e
          rw [hT] at hca het
          have hval := atom_use_val hq1 hd hv hcv0' hca
          dsimp only at hval
          simp only [EdgeTaken] at het
          rw [hval]
          constructor
          · intro hnz; rw [het, ite_eq_left hnz]
          · intro hs1 hz
            rw [het, ite_eq_right (fun hc => hc hz)] at hs1
            exact hne hs1.symm
        obtain ⟨node, hnode, h⟩ := bind_eq_ok h
        have hnd := nodes_get_ok hnode
        -- the first fact, common to every case
        have hfirst : ∀ (B : Block), f.blocks.val[p.val.toNat]? = some B →
            ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
              CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s →
              FactOK vg1 env (qbe_tv.Fact.mk s cv (!(s == s1))) := by
          intro B hB W o regs env hca het
          have hr := hrun B hB o regs env hca het
          refine ⟨vcv, fun hz => ?_, fun hnz => ?_⟩
          · simp only [Bool.not_eq_true', beq_eq_false_iff_ne, ne_eq] at hz
            by_contra hc; exact hz (hr.1 hc)
          · simp only [Bool.not_eq_false', beq_iff_eq] at hnz
            exact hr.2 hnz
        have hblk1 : ∀ fa ∈ [qbe_tv.Fact.mk s cv (!(s == s1))], fa.blk = s := by simp
        have hone : q = (Pion.Array.push (Pion.Array.ofList []) (qbe_tv.Fact.mk s cv (!(s == s1))), vg1) →
            vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧ (∀ fa ∈ q.1.val, fa.blk = s) ∧
            ∀ (B : Block), 0 ≤ p.val → f.blocks.val[p.val.toNat]? = some B →
              ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
                CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s →
                FactsHold q.2 env q.1.val := by
          rintro rfl
          refine ⟨e1, d1, fun fa hfa => by simp at hfa; rw [hfa], fun B _ hB W o regs env hca het fa hfa => ?_⟩
          simp at hfa; subst hfa; exact hfirst B hB o regs env hca het
        cases node
        case SBin c0 op x y =>
          have hx := (child_bin d1 hnd).1
          have hval : ∀ env, evI vg1 env cv = (evalBin c0 op (evI vg1 env x) (evI vg1 env y)).getD 0 := by
            intro env; rw [evI_node d1 env hnd]; rfl
          cases op
          case CEq cc =>
            try simp only at h
            obtain ⟨t5, ht5, h⟩ := bind_eq_ok h
            obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
            split at h
            · rename_i h7
              have h5 : t5 = true := by cases t5 <;> simp_all
              rw [h5] at ht5 ht7
              obtain ⟨hy0, hl1⟩ := vg_is_const_true ht5
              simp only [↓reduceIte, vg_cls_eq hl1, bind_ok] at ht7
              cases ok_inj' ht7
              simp only [beq_iff_eq] at h7
              cases ok_inj' h
              refine ⟨e1, d1, fun fa hfa => by
                  simp only [Pion.Array.push, Pion.Array.ofList, List.nil_append, List.cons_append, List.mem_cons,
                    List.not_mem_nil, or_false] at hfa
                  rcases hfa with rfl | rfl <;> rfl,
                fun B _ hB W o regs env hca het fa hfa => ?_⟩
              simp only [Pion.Array.push, Pion.Array.ofList, List.nil_append, List.cons_append, List.mem_cons,
                List.not_mem_nil, or_false] at hfa
              rcases hfa with rfl | rfl
              · exact hfirst B hB o regs env hca het
              · have hr := hrun B hB o regs env hca het
                have hm := evI_masked d1 env hx
                rw [h7] at hm
                have hcv := hval env
                have hy : evI vg1 env y = 0 := by rw [constOf_evI d1 env hy0]; rfl
                rw [hy] at hcv
                simp only [evalBin, Option.getD_some, b2v, maskC_zero, hm] at hcv
                dsimp only
                refine ⟨hx, fun hz => ?_, fun hnz => ?_⟩
                · simp only [beq_iff_eq] at hz
                  by_contra hc
                  apply hr.2 hz
                  rw [hcv]; simp; exact hc
                · simp only [beq_eq_false_iff_ne, ne_eq] at hnz
                  intro hc
                  apply hnz
                  apply hr.1
                  rw [hcv]; simp [hc]
            · cases ok_inj' h
              exact hone rfl
          case CNe cc =>
            try simp only at h
            obtain ⟨t5, ht5, h⟩ := bind_eq_ok h
            obtain ⟨t7, ht7, h⟩ := bind_eq_ok h
            split at h
            · rename_i h7
              have h5 : t5 = true := by cases t5 <;> simp_all
              rw [h5] at ht5 ht7
              obtain ⟨hy0, hl1⟩ := vg_is_const_true ht5
              simp only [↓reduceIte, vg_cls_eq hl1, bind_ok] at ht7
              cases ok_inj' ht7
              simp only [beq_iff_eq] at h7
              cases ok_inj' h
              refine ⟨e1, d1, fun fa hfa => by
                  simp only [Pion.Array.push, Pion.Array.ofList, List.nil_append, List.cons_append, List.mem_cons,
                    List.not_mem_nil, or_false] at hfa
                  rcases hfa with rfl | rfl <;> rfl,
                fun B _ hB W o regs env hca het fa hfa => ?_⟩
              simp only [Pion.Array.push, Pion.Array.ofList, List.nil_append, List.cons_append, List.mem_cons,
                List.not_mem_nil, or_false] at hfa
              rcases hfa with rfl | rfl
              · exact hfirst B hB o regs env hca het
              · have hr := hrun B hB o regs env hca het
                have hm := evI_masked d1 env hx
                rw [h7] at hm
                have hcv := hval env
                have hy : evI vg1 env y = 0 := by rw [constOf_evI d1 env hy0]; rfl
                rw [hy] at hcv
                simp only [evalBin, Option.getD_some, b2v, maskC_zero, hm] at hcv
                dsimp only
                refine ⟨hx, fun hz => ?_, fun hnz => ?_⟩
                · simp only [Bool.not_eq_true', beq_eq_false_iff_ne, ne_eq] at hz
                  by_contra hc
                  apply hz
                  apply hr.1
                  rw [hcv]; simp; exact hc
                · simp only [Bool.not_eq_false', beq_iff_eq] at hnz
                  intro hc
                  apply hr.2 hnz
                  rw [hcv]; simp [hc]
            · cases ok_inj' h
              exact hone rfl
          all_goals (try simp only at h); exact hone (ok_inj' h).symm
        all_goals (try simp only at h); exact hone (ok_inj' h).symm
      · cases ok_inj' h
        exact hnil vg1 e1 d1 rfl
    · exact hnil vg (vg_extends_refl _) hd (ok_inj' h).symm
  | _ => exact hnil vg (vg_extends_refl _) hd (ok_inj' h).symm

theorem retarget_spec {fs : Pion.Array Fact} {b : Std.I32} {out : Pion.Array Fact}
    (h : retarget fs b = ok out) : out.val = fs.val.map (fun fa => qbe_tv.Fact.mk b fa.vid fa.zero) := by
  unfold retarget at h
  obtain ⟨r, hr, h⟩ := bind_eq_ok h
  obtain ⟨i1, o1⟩ := r
  have := ok_inj' h
  subst this
  have key := loop_ok_inv (fun (p : Std.I32 × Pion.Array Fact) => retarget_loop0.body fs b p.1 p.2)
    (fun p => 0 ≤ p.1.val ∧ p.1.val ≤ fs.val.length ∧
      p.2.val = (fs.val.take p.1.val.toNat).map (fun fa => qbe_tv.Fact.mk b fa.vid fa.zero))
    (fun p => p.2.val = fs.val.map (fun fa => qbe_tv.Fact.mk b fa.vid fa.zero))
    (by
      rintro ⟨i, o⟩ c ⟨hi0, hil, hio⟩ hc
      simp only at hi0 hil hio
      unfold retarget_loop0.body at hc
      simp only at hc
      obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
      obtain ⟨ht1, ht2⟩ := arr_length_ok ht
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, ht1] at hlt
        obtain ⟨fa, hfa, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hfl, hfv⟩ := arr_get_ok hfa
        have hs := i32_succ_val' hlt ht2
        have htake : fs.val.take (i.val.toNat + 1) = fs.val.take i.val.toNat ++ [fa] := by
          rw [List.take_add_one, List.getElem?_eq_getElem hfl, hfv]; rfl
        rw [← ok_inj' hc]
        simp only
        refine ⟨by omega, by omega, ?_⟩
        rw [show (Pion.I32.add i 1#i32).val.toNat = i.val.toNat + 1 by omega, htake, List.map_append, ← hio]
        rfl
      · rename_i hge
        simp only [i32_lt_iff, ht1, not_lt] at hge
        rw [← ok_inj' hc]
        simp only
        rw [hio, List.take_of_length_le (by omega)])
  exact key _ _ hr ⟨by simp, by simp, by simp⟩

/-- The facts of `p` (as facts of `s`) and of the edge `p -> s` hold on every run taking it. -/
theorem edge_fact_set_sound {vg : ValGraph} {f : Func} {vids : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {p s : Std.I32} {q : Pion.Array Fact × ValGraph}
    (h : edge_fact_set vg f vids facts p s = ok q) (hd : ValGraphDAG vg) (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      ∀ (B : Block), 0 ≤ p.val → f.blocks.val[p.val.toNat]? = some B →
        ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
          CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term s →
          (∀ fb ∈ facts.val, fb.blk = p → FactOK vg env fb) → FactsHold q.2 env q.1.val := by
  unfold edge_fact_set at h
  obtain ⟨fp, hfp, h⟩ := bind_eq_ok h
  obtain ⟨out, hout, h⟩ := bind_eq_ok h
  obtain ⟨q1, hq1, h⟩ := bind_eq_ok h
  obtain ⟨ef, vg1⟩ := q1
  try simp only [uncurry_apply_pair] at h
  obtain ⟨q2, hq2, h⟩ := bind_eq_ok h
  obtain ⟨i1, out1⟩ := q2
  cases ok_inj' h
  obtain ⟨e1, d1, -, hef⟩ := edge_facts_sound hq1 hd hv
  dsimp only at e1 d1 hef
  -- every pushed fact comes from `out` or `ef`
  have hmem : ∀ fa ∈ out1.val, fa ∈ out.val ∨ fa ∈ ef.val := by
    have key := loop_ok_inv (fun (x : Std.I32 × Pion.Array Fact) => edge_fact_set_loop0.body ef x.1 x.2)
      (fun x => ∀ fa ∈ x.2.val, fa ∈ out.val ∨ fa ∈ ef.val)
      (fun x => ∀ fa ∈ x.2.val, fa ∈ out.val ∨ fa ∈ ef.val)
      (by
        rintro ⟨i, o⟩ c hio hc
        simp only at hio hc
        unfold edge_fact_set_loop0.body at hc
        obtain ⟨t, -, hc⟩ := bind_eq_ok hc
        split at hc
        · obtain ⟨fa, hfa, hc⟩ := bind_eq_ok hc
          obtain ⟨_, hfl, hfv⟩ := arr_get_ok hfa
          obtain ⟨t5, -, hc⟩ := bind_eq_ok hc
          obtain ⟨o1, ho1, hc⟩ := bind_eq_ok hc
          rw [← ok_inj' hc]
          intro fb hfb
          split at ho1
          · cases ok_inj' ho1
            simp only [Pion.Array.push, List.mem_append, List.mem_singleton] at hfb
            rcases hfb with hfb | rfl
            · exact hio fb hfb
            · right; rw [← hfv]; exact List.getElem_mem _
          · cases ok_inj' ho1
            exact hio fb hfb
        · rw [← ok_inj' hc]; exact hio)
    exact key _ _ hq2 (fun fa hfa => Or.inl hfa)
  have hout' := retarget_spec hout
  refine ⟨e1, d1, fun B hp0 hB W o regs env hca het hfacts fa hfa => ?_⟩
  rcases hmem fa hfa with hfa | hfa
  · rw [hout'] at hfa
    obtain ⟨fb, hfb, rfl⟩ := List.mem_map.1 hfa
    obtain ⟨hfb1, hfb2⟩ := mem_facts_of hfp hfb
    have := factOK_extends e1 (hfacts fb hfb1 hfb2)
    exact this
  · exact hef B hp0 hB o regs env hca het fa hfa

/-- `check_facts`: every fact of a block holds whenever the block is entered (and does not depend
on the block itself). -/
theorem check_facts_sound {vg : ValGraph} {f : Func} {info : FnInfo} {vids : Pion.Array Std.I32}
    {facts : Pion.Array Fact} {q : Std.I32 × ValGraph} (h : check_facts vg f info vids facts = ok q)
    (h0 : q.1 = 0#i32) (hd : ValGraphDAG vg) (hinfo : InfoOK f info) (hv : VidsOK vg vids.val) :
    vg_extends vg q.2 ∧ ValGraphDAG q.2 ∧
      ∀ fa ∈ facts.val, 0 < fa.blk.val ∧ fa.blk.val < f.blocks.val.length ∧
        info.reach.val[fa.blk.val.toNat]? = some true ∧ Valid q.2 fa.vid ∧
        (∀ env env', AgreeExcept fa.blk env env' → evI q.2 env' fa.vid = evI q.2 env fa.vid) ∧
        ∀ (pb : Nat) (B : Block), info.reach.val[pb]? = some true → f.blocks.val[pb]? = some B →
          fa.blk ∈ termSuccs B.term →
          ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
            CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term fa.blk →
            (∀ fb ∈ facts.val, fb.blk.val = pb → FactOK q.2 env fb) → FactOK q.2 env fa := by
  -- what one fact needs, in every graph extending the current one
  let EdgeOK : qbe_tv.Fact → Nat → ValGraph → Prop := fun fa pb G =>
    ∀ (B : Block), info.reach.val[pb]? = some true →
      f.blocks.val[pb]? = some B → fa.blk ∈ termSuccs B.term →
      ∀ {W : Type} (o : WorldOracle W) (regs : Nat → BitVec 64) (env : SymEnv),
        CondAgree vg env vids.val o regs B.term → EdgeTaken o regs B.term fa.blk →
        (∀ fb ∈ facts.val, fb.blk.val = pb → FactOK G env fb) → FactOK G env fa
  let Good : ValGraph → qbe_tv.Fact → Prop := fun g fa =>
    0 < fa.blk.val ∧ fa.blk.val < f.blocks.val.length ∧ info.reach.val[fa.blk.val.toNat]? = some true ∧
      Valid g fa.vid ∧ (∀ env env', AgreeExcept fa.blk env env' → evI g env' fa.vid = evI g env fa.vid) ∧
      ∀ pb, ∀ G : ValGraph, vg_extends g G → EdgeOK fa pb G
  have hnb := hinfo.nb
  have hlenle : f.blocks.val.length ≤ 2147483647 := by have := i32_val_le info.nb; omega
  unfold check_facts at h
  obtain ⟨r0, hr0, h⟩ := bind_eq_ok h
  -- the scan over the predecessors of one fact's block
  have loop1 : ∀ (fa : qbe_tv.Fact) (vga : ValGraph), vg_extends vg vga → ValGraphDAG vga → 0 < fa.blk.val →
      fa.blk.val < f.blocks.val.length →
      ∀ (x : Std.I32 × ValGraph) r, check_facts_loop1 info.nb info f fa.blk facts fa vids x.1 x.2 = ok r →
      (0 ≤ x.1.val ∧ vg_extends vga x.2 ∧ ValGraphDAG x.2 ∧
        ∀ pb, pb < x.1.val.toNat → ∀ G, vg_extends x.2 G → EdgeOK fa pb G) →
      match r with
      | .inl e => e.1 ≠ 0#i32
      | .inr y => vg_extends vga y.2 ∧ ValGraphDAG y.2 ∧
          ∀ pb, pb < f.blocks.val.length → ∀ G, vg_extends y.2 G → EdgeOK fa pb G := by
    intro fa vga ea da hb0 hbl x r hx hinv
    unfold check_facts_loop1 at hx
    refine loop_ok_inv (fun (x : Std.I32 × ValGraph) =>
        match x with | (p, vg) => check_facts_loop1.body info.nb info f fa.blk facts fa vids p vg)
      (fun (x : Std.I32 × ValGraph) => 0 ≤ x.1.val ∧ vg_extends vga x.2 ∧ ValGraphDAG x.2 ∧
        ∀ pb, pb < x.1.val.toNat → ∀ G, vg_extends x.2 G → EdgeOK fa pb G)
      (fun r => match r with
        | .inl e => e.1 ≠ 0#i32
        | .inr y => vg_extends vga y.2 ∧ ValGraphDAG y.2 ∧
            ∀ pb, pb < f.blocks.val.length → ∀ G, vg_extends y.2 G → EdgeOK fa pb G) ?_ x r hx hinv
    rintro ⟨pp, vgp⟩ c ⟨hp0, hep, hdp, hall⟩ hc
    simp only at hp0 hep hdp hall hc
    unfold check_facts_loop1.body at hc
    split at hc
    · rename_i hlt
      have hlt' : pp.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb] using hlt
      have hps := i32_succ_val' hlt' hlenle
      obtain ⟨t6, ht6, hc⟩ := bind_eq_ok hc
      obtain ⟨_, ht6l, ht6v⟩ := arr_get_ok ht6
      obtain ⟨t8, ht8, hc⟩ := bind_eq_ok hc
      obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
      -- what this predecessor gives
      have hstep : ∀ vg2 : ValGraph, sres = .inr vg2 → vg_extends vgp vg2 ∧ ValGraphDAG vg2 ∧
          ∀ G, vg_extends vg2 G → EdgeOK fa pp.val.toNat G := by
        intro vg2 hs2
        subst hs2
        split at hsres
        · rename_i ht8t
          have ht6t : t6 = true := by
            cases t6
            · cases ok_inj' ht8; cases ht8t
            · rfl
          rw [ht6t] at ht8
          simp only [↓reduceIte] at ht8
          obtain ⟨t9, ht9, hsres⟩ := bind_eq_ok hsres
          split at hsres
          · rename_i ht9f
            obtain ⟨q1, hq1, hsres⟩ := bind_eq_ok hsres
            obtain ⟨ef, vg1⟩ := q1
            try simp only [uncurry_apply_pair] at hsres
            obtain ⟨t12, ht12, hsres⟩ := bind_eq_ok hsres
            split at hsres
            · cases ok_inj' hsres
            · rename_i ht12t
              cases ok_inj' hsres
              have hvp := vidsOK_extends (vg_extends_trans ea hep) hv
              obtain ⟨e1, d1, -, hef⟩ := edge_facts_sound hq1 hdp hvp
              dsimp only at e1 d1 hef
              obtain ⟨fe, hfe, hfev, hfez⟩ := (fact_in_spec ht12).1 (by simpa using ht12t)
              refine ⟨e1, d1, fun G eG B hreach hB hsucc W o regs env hca het hfb => ?_⟩
              have hBp := hB
              rw [show pp.val.toNat = pp.val.toNat from rfl] at hBp
              have hfs := hef B hp0 hBp o regs env
                (condAgree_extends (vg_extends_trans ea hep) hv hca) het fe hfe
              have hfsG := factOK_extends eG hfs
              obtain ⟨hv1, hz1, hn1⟩ := hfsG
              rw [hfev] at hv1 hz1 hn1
              rw [hfez] at hz1 hn1
              exact ⟨hv1, hz1, hn1⟩
          · rename_i ht9t
            cases ok_inj' hsres
            obtain ⟨fb, hfb, hfbb, hfbv, hfbz⟩ := fact_in_blk_spec ht9 (by simpa using ht9t)
            refine ⟨vg_extends_refl _, hdp, fun G eG B hreach hB hsucc W o regs env hca het hall' => ?_⟩
            have hfbok := hall' fb hfb (by rw [hfbb]; omega)
            obtain ⟨hv1, hz1, hn1⟩ := hfbok
            rw [hfbv] at hv1 hz1 hn1
            rw [hfbz] at hz1 hn1
            exact ⟨hv1, hz1, hn1⟩
        · rename_i ht8f
          cases ok_inj' hsres
          refine ⟨vg_extends_refl _, hdp, fun G eG B hreach hB hsucc W o regs env hca het hall' => ?_⟩
          exfalso
          cases t6
          · rw [List.getElem?_eq_getElem ht6l, ht6v] at hreach; cases hreach
          · simp only [↓reduceIte] at ht8
            obtain ⟨t7, ht7, ht8'⟩ := bind_eq_ok ht8
            have e78 : t7 = t8 := ok_inj' ht8'
            have hf : t7 = false := by rw [e78]; cases t8 <;> simp_all
            rw [hf] at ht7
            exact is_edge_false ht7 B hp0 hB hsucc
      cases sres with
      | inl e =>
        simp only at hc
        rw [← ok_inj' hc]
        simp only
        split at hsres
        · obtain ⟨t9, -, hsres⟩ := bind_eq_ok hsres
          split at hsres
          · obtain ⟨q1, -, hsres⟩ := bind_eq_ok hsres
            obtain ⟨ef, vg1⟩ := q1
            try simp only [uncurry_apply_pair] at hsres
            obtain ⟨t12, -, hsres⟩ := bind_eq_ok hsres
            split at hsres
            · cases ok_inj' hsres
              simp only
              intro he
              have := congrArg (·.val) he
              simp only [i32_zero_val] at this
              rw [i32_succ_val' (m := f.blocks.val.length) (by omega) hlenle] at this
              omega
            · cases ok_inj' hsres
          · cases ok_inj' hsres
        · cases ok_inj' hsres
      | inr vg2 =>
        simp only at hc
        rw [← ok_inj' hc]
        dsimp only
        obtain ⟨e2, d2, h2⟩ := hstep vg2 rfl
        refine ⟨by omega, vg_extends_trans hep e2, d2, fun pb hpb G eG => ?_⟩
        by_cases hpp : pb = pp.val.toNat
        · subst hpp; exact h2 G eG
        · exact hall pb (by omega) G (vg_extends_trans e2 eG)
    · rename_i hge
      have hge' : f.blocks.val.length ≤ pp.val := by simpa [i32_lt_iff, hnb] using hge
      rw [← ok_inj' hc]
      exact ⟨hep, hdp, fun pb hpb G eG => hall pb (by omega) G eG⟩
  have good_mono : ∀ g g' fa, vg_extends g g' → Good g fa → Good g' fa := by
    intro g g' fa e ⟨h1, h2, h3, h4, h5, h6⟩
    refine ⟨h1, h2, h3, extends_valid e h4, fun env env' ha => ?_, fun pb G eG => h6 pb G (vg_extends_trans e eG)⟩
    rw [extends_evI e env' h4, extends_evI e env h4, h5 env env' ha]
  unfold check_facts_loop0 at hr0
  let TabOK : ValGraph → Std.I32 → Pion.Array Bool → Prop := fun g mb m =>
    ∀ j, m.val[j]? = some false → j < g.nodes.val.length ∧ Indep g mb j
  have key := loop_ok_inv (fun (x : Std.I32 × ValGraph × Std.I32 × Pion.Array Bool) =>
      match x with | (i, vg, mb, m) => check_facts_loop0.body facts info.nb info f vids i vg mb m)
    (fun (x : Std.I32 × ValGraph × Std.I32 × Pion.Array Bool) => 0 ≤ x.1.val ∧ vg_extends vg x.2.1 ∧
      ValGraphDAG x.2.1 ∧ TabOK x.2.1 x.2.2.1 x.2.2.2 ∧
      ∀ k, k < x.1.val.toNat → ∀ hk : k < facts.val.length, Good x.2.1 (facts.val[k]))
    (fun r => match r with
      | .inl e => e.1 ≠ 0#i32
      | .inr y => vg_extends vg y.2.1 ∧ ValGraphDAG y.2.1 ∧
          ∀ k, ∀ hk : k < facts.val.length, Good y.2.1 (facts.val[k])) ?_ _ _ hr0
    ⟨by simp, vg_extends_refl _, hd, fun j hj => by simp at hj, fun k hk => by simp at hk⟩
  · cases r0 with
    | inl e =>
      simp only at h
      cases ok_inj' h
      exact absurd h0 key
    | inr y =>
      obtain ⟨i1, vg1, mb1, m1⟩ := y
      simp only at h
      cases ok_inj' h
      obtain ⟨e1, d1, hall⟩ := key
      refine ⟨e1, d1, fun fa hfa => ?_⟩
      obtain ⟨k, hk, rfl⟩ := List.getElem_of_mem hfa
      obtain ⟨h1, h2, h3, h4, h5, h6⟩ := hall k hk
      exact ⟨h1, h2, h3, h4, h5, fun pb => h6 pb vg1 (vg_extends_refl _)⟩
  rintro ⟨ii, vgk, mbk, mk⟩ c ⟨hi0, hek, hdk, htk, hallk⟩ hc
  simp only at hi0 hek hdk htk hallk hc
  unfold check_facts_loop0.body at hc
  obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
  obtain ⟨ht1, ht2⟩ := arr_length_ok ht
  split at hc
  · rename_i hlt
    simp only [i32_lt_iff, ht1] at hlt
    have his := i32_succ_val' hlt ht2
    obtain ⟨fa, hfa, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hfal, hfav⟩ := arr_get_ok hfa
    try simp only at hc
    obtain ⟨t2, ht2', hc⟩ := bind_eq_ok hc
    split at hc
    · rw [← ok_inj' hc]; show (1#i32 : Std.I32) ≠ 0#i32; decide
    rename_i ht2f
    have hrange : 0 < fa.blk.val ∧ fa.blk.val < f.blocks.val.length ∧
        info.reach.val[fa.blk.val.toNat]? = some true := by
      split at ht2'
      · cases ok_inj' ht2'; exact absurd rfl ht2f
      · rename_i hcond
        simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, not_le, i32_le_iff,
          i32_zero_val, hnb] at hcond
        obtain ⟨t1, ht1', ht2'⟩ := bind_eq_ok ht2'
        obtain ⟨_, ht1l, ht1v⟩ := arr_get_ok ht1'
        cases ok_inj' ht2'
        refine ⟨by omega, by omega, ?_⟩
        rw [List.getElem?_eq_getElem ht1l, ht1v]
        cases t1
        · exact absurd rfl ht2f
        · rfl
    obtain ⟨hb0, hbl, hbr⟩ := hrange
    have hne0 : Pion.I32.add fa.blk 1#i32 ≠ 0#i32 := by
      intro he
      have := congrArg (·.val) he
      simp only [i32_zero_val] at this
      rw [i32_succ_val' (m := f.blocks.val.length) hbl hlenle] at this
      omega
    obtain ⟨t3, ht3, hc⟩ := bind_eq_ok hc
    split at hc
    · rw [← ok_inj' hc]
      exact hne0
    rename_i ht3f
    obtain ⟨ht3a, -⟩ := vg_valid_ok ht3
    have ht3t : t3 = true := by cases t3 <;> simp_all
    have hvv : Valid vgk fa.vid := ht3a.1 ht3t
    obtain ⟨q, hq, hc⟩ := bind_eq_ok hc
    obtain ⟨m1, mb1⟩ := q
    try simp only [uncurry_apply_pair] at hc
    have hT : mb1 = fa.blk ∧ TabOK vgk mb1 m1 := by
      split at hq
      · obtain ⟨m2, hm2, hq⟩ := bind_eq_ok hq
        have := ok_inj' hq
        simp only [Prod.mk.injEq] at this
        obtain ⟨rfl, rfl⟩ := this
        obtain ⟨hl2, hi2⟩ := blk_mentions_table_sound hm2
        refine ⟨rfl, fun j hj => ⟨?_, hi2 j hj⟩⟩
        rw [← hl2]
        by_contra hc'
        rw [List.getElem?_eq_none (by omega)] at hj
        cases hj
      · rename_i hne
        have := ok_inj' hq
        simp only [Prod.mk.injEq] at this
        obtain ⟨rfl, rfl⟩ := this
        exact ⟨not_not.mp hne, htk⟩
    obtain ⟨hmb, hT⟩ := hT
    obtain ⟨t5, -, hc⟩ := bind_eq_ok hc
    obtain ⟨t7, ht7, hc⟩ := bind_eq_ok hc
    split at hc
    · rw [← ok_inj' hc]
      exact hne0
    rename_i ht7f
    have hind : Indep vgk fa.blk fa.vid.val.toNat := by
      split at ht7
      · cases ok_inj' ht7
        exact absurd rfl ht7f
      · obtain ⟨t6, ht6, ht7⟩ := bind_eq_ok ht7
        have := ok_inj' ht7
        subst this
        obtain ⟨_, ht6l, ht6v⟩ := arr_get_ok ht6
        have hf : m1.val[fa.vid.val.toNat]? = some false := by
          rw [List.getElem?_eq_getElem ht6l, ht6v]
          cases t6
          · rfl
          · exact absurd rfl ht7f
        have := (hT _ hf).2
        rw [hmb] at this
        exact this
    obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
    have h1 := loop1 fa vgk hek hdk hb0 hbl (0#i32, vgk) sres hsres
      ⟨by simp, vg_extends_refl _, hdk, fun pb hpb => by simp at hpb⟩
    cases sres with
    | inl e =>
      simp only at hc
      rw [← ok_inj' hc]
      exact h1
    | inr y =>
      obtain ⟨p1, vg1⟩ := y
      simp only at hc
      rw [← ok_inj' hc]
      dsimp only
      obtain ⟨e1, d1, hedge⟩ := h1
      dsimp only at e1 d1 hedge
      refine ⟨by omega, vg_extends_trans hek e1, d1,
        fun j hj => ⟨?_, indep_extends e1 (hT j hj).1 (hT j hj).2⟩, fun k hk hk' => ?_⟩
      · have := (hT j hj).1
        have := List.IsPrefix.length_le e1
        omega
      by_cases hki : k = ii.val.toNat
      · subst hki
        rw [hfav]
        refine ⟨hb0, hbl, hbr, extends_valid e1 hvv, fun env env' ha => ?_, fun pb G eG => ?_⟩
        · have := hind env env' ha
          rw [extends_evI e1 env' hvv, extends_evI e1 env hvv]
          exact this
        · intro B hreach hB hsucc W o regs env hca het hfb
          have hpb : pb < f.blocks.val.length := by
            by_contra hc'
            rw [List.getElem?_eq_none (by omega)] at hB
            cases hB
          exact hedge pb hpb G eG B hreach hB hsucc o regs env hca het hfb
      · exact good_mono _ _ _ e1 (hallk k (by omega) hk')
  · rename_i hge
    simp only [i32_lt_iff, ht1, not_lt] at hge
    rw [← ok_inj' hc]
    exact ⟨hek, hdk, fun k hk => hallk k (by omega) hk⟩

/-! ## `check_avail` -/

/-- The `Int` id `n` (`n < 2 ^ 31`). -/
def i32n (n : Nat) : Std.I32 := ⟨BitVec.ofNat 32 n⟩

theorem i32n_val {n : Nat} (h : n < 2147483648) : (i32n n).val = n := i32_ofNat_val n h

theorem i32n_of_val {x : Std.I32} (h : 0 ≤ x.val) : x = i32n x.val.toNat := by
  apply i32_ext
  rw [i32n_val (by have := i32_val_le x; omega)]
  omega

/-- Temp `t` is available at the entry of block `b` (`av[b * nt + t]`, with the checker's own
index arithmetic). -/
def AvB (av : Pion.Array Bool) (nt : Std.I32) (b t : Nat) : Prop :=
  av.get (Pion.I32.add (Pion.I32.mul (i32n b) nt) (i32n t)) = ok true

def AvailAtom (cur : Nat → Prop) : Atom → Prop
  | .Temp t => 0 ≤ t.val ∧ cur t.val.toNat
  | _ => True

def AvailInst (cur : Nat → Prop) : Inst → Prop
  | .Par _ _ _ => True
  | .Un _ _ _ a => AvailAtom cur a
  | .Bin _ _ _ a b => AvailAtom cur a ∧ AvailAtom cur b
  | .Load _ _ _ _ a => AvailAtom cur a
  | .Store _ v a => AvailAtom cur v ∧ AvailAtom cur a
  | .Call _ _ _ c args => AvailAtom cur c ∧ ∀ x ∈ args.val, AvailAtom cur x.arg
  | .Alloc _ _ _ => True

def AvailTerm (cur : Nat → Prop) : Term → Prop
  | .Jnz a _ _ => AvailAtom cur a
  | .Ret h _ a => h = true → AvailAtom cur a
  | _ => True

theorem availAtom_mono {cur cur' : Nat → Prop} (hm : ∀ t, cur t → cur' t) {a : Atom}
    (h : AvailAtom cur a) : AvailAtom cur' a := by
  cases a with
  | Temp t => exact ⟨h.1, hm _ h.2⟩
  | _ => trivial

/-- Temps initialised after the phis and the first `i` instructions of block `B` entered with
the temps `avb` available. -/
def CurAt (nt : Nat) (avb : Nat → Prop) (B : Block) (i : Nat) (t : Nat) : Prop :=
  t < nt ∧ (avb t ∨ (∃ P ∈ B.phis.val, P.dst.val = t) ∨
    ∃ k < i, ∃ hk : k < B.insts.val.length, (instDst B.insts.val[k]).val = t)

/-- The arm of phi `P` on the edge from block `prev` (first arm with that predecessor). -/
theorem phiArg_of_index {P : Phi} {prev : Nat} {ai : Nat} (hai : ai < P.arms.val.length)
    (hp : P.arms.val[ai].pred.val = prev)
    (hfirst : ∀ j < ai, ∀ hj : j < P.arms.val.length, P.arms.val[j].pred.val ≠ prev) :
    phiArg P prev = some P.arms.val[ai].value := by
  unfold phiArg
  suffices h : P.arms.val.find? (fun a => decide (a.pred.val = (prev : Int))) = some P.arms.val[ai] by
    rw [h]; rfl
  rw [List.find?_eq_some_iff_getElem]
  refine ⟨by simp [hp], ai, hai, rfl, fun j hj => ?_⟩
  simp only [Bool.not_eq_true', decide_eq_false_iff_not]
  exact hfirst j hj (by omega)

/-- What `check_avail` certifies. -/
structure AvailOK (vg : ValGraph) (f : Func) (info : FnInfo) (av : Pion.Array Bool)
    (vids : List Std.I32) (bm_t bm_s : List Std.I32) : Prop where
  nt_eq : vids.length = info.nt.val.toNat
  nt_nonneg : 0 ≤ info.nt.val
  entry : ∀ t, t < info.nt.val.toNat → ¬ AvB av info.nt 0 t
  scope : ∀ b, info.reach.val[b]? = some true → b < f.blocks.val.length →
    ∀ (j : Nat) (sb : Std.I32), bm_t[j]? = some (i32n b) → bm_s[j]? = some sb →
    ∀ x, x < info.nt.val.toNat → AvB av info.nt b x → ∀ v, vids[x]? = some v → 0 ≤ v.val →
      Valid vg v ∧ Indep vg sb v.val.toNat
  block : ∀ b (B : Block), info.reach.val[b]? = some true → f.blocks.val[b]? = some B →
    (∀ P ∈ B.phis.val, 0 ≤ P.dst.val ∧ P.dst.val < info.nt.val) ∧
    (∀ i (hi : i < B.insts.val.length),
      AvailInst (CurAt info.nt.val.toNat (AvB av info.nt b) B i) B.insts.val[i] ∧
      (0 ≤ (instDst B.insts.val[i]).val → (instDst B.insts.val[i]).val < info.nt.val)) ∧
    AvailTerm (CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length) B.term ∧
    ∀ s ∈ termSuccs B.term, 0 < s.val ∧ s.val < f.blocks.val.length ∧
      (∀ z, z < info.nt.val.toNat → AvB av info.nt s.val.toNat z →
        CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length z) ∧
      ∃ S, f.blocks.val[s.val.toNat]? = some S ∧ ∀ P ∈ S.phis.val, ∃ a, phiArg P b = some a ∧
        AvailAtom (CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length) a

theorem avail_atom_true {cur : Pion.Array Bool} {a : Atom} (h : avail_atom cur a = ok true) :
    AvailAtom (fun t => cur.val[t]? = some true) a := by
  unfold avail_atom at h
  cases a with
  | Temp t =>
    simp only at h
    obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
    split at h
    · rename_i htt
      obtain ⟨v, hv, h⟩ := bind_eq_ok h
      obtain ⟨h0, hl, hvv⟩ := arr_get_ok hv
      cases ok_inj' h
      refine ⟨h0, ?_⟩
      show cur.val[t.val.toNat]? = some true
      rw [List.getElem?_eq_getElem hl, hvv]
    · cases ok_inj' h
  | _ => trivial

theorem avail_inst_ops_true {cur : Pion.Array Bool} {inst : Inst} (h : avail_inst_ops cur inst = ok true) :
    AvailInst (fun t => cur.val[t]? = some true) inst := by
  unfold avail_inst_ops at h
  cases inst with
  | Par _ _ _ => trivial
  | Un _ _ _ a => simp only at h; exact avail_atom_true (by obtain ⟨x, hx, h⟩ := bind_eq_ok h; cases ok_inj' h; exact hx)
  | Bin _ _ _ a b =>
    simp only at h
    obtain ⟨x, hx, h⟩ := bind_eq_ok h
    split at h
    · rename_i hxt
      obtain ⟨y, hy, h⟩ := bind_eq_ok h
      cases ok_inj' h
      rw [hxt] at hx
      exact ⟨avail_atom_true hx, avail_atom_true hy⟩
    · cases ok_inj' h
  | Load _ _ _ _ a => simp only at h; exact avail_atom_true (by obtain ⟨x, hx, h⟩ := bind_eq_ok h; cases ok_inj' h; exact hx)
  | Store _ v a =>
    simp only at h
    obtain ⟨x, hx, h⟩ := bind_eq_ok h
    split at h
    · rename_i hxt
      obtain ⟨y, hy, h⟩ := bind_eq_ok h
      cases ok_inj' h
      rw [hxt] at hx
      exact ⟨avail_atom_true hx, avail_atom_true hy⟩
    · cases ok_inj' h
  | Call _ _ _ c args =>
    simp only at h
    obtain ⟨x, hx, h⟩ := bind_eq_ok h
    split at h
    · cases ok_inj' h
    rename_i hxf
    have hxt : x = true := by cases x <;> simp_all
    rw [hxt] at hx
    refine ⟨avail_atom_true hx, ?_⟩
    obtain ⟨r, hr, h⟩ := bind_eq_ok h
    have key := scan_loop (fun i => avail_inst_ops_loop0.body args cur i) args.val.length
      (fun k => ∀ hk : k < args.val.length, AvailAtom (fun t => cur.val[t]? = some true) args.val[k].arg)
      (fun _ b => b = false) (fun _ => True)
      (by
        intro i c hi hc
        unfold avail_inst_ops_loop0.body at hc
        obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
        obtain ⟨ht1, ht2⟩ := arr_length_ok ht
        split at hc
        · rename_i hlt
          simp only [i32_lt_iff, ht1] at hlt
          obtain ⟨y, hy, hc⟩ := bind_eq_ok hc
          obtain ⟨_, hyl, hyv⟩ := arr_get_ok hy
          obtain ⟨a11, ha11, hc⟩ := bind_eq_ok hc
          left
          refine ⟨hlt, ht2, ?_⟩
          split at hc
          · left; exact ⟨false, (ok_inj' hc).symm, rfl⟩
          · rename_i hn
            right
            have : a11 = true := by cases a11 <;> simp_all
            rw [this] at ha11
            exact ⟨fun hk => by rw [hyv]; exact avail_atom_true ha11, (ok_inj' hc).symm⟩
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
      intro x hx
      obtain ⟨k, hkl, rfl⟩ := List.getElem_of_mem hx
      exact hk.2 k (by simp) hkl hkl
  | Alloc _ _ _ => trivial

theorem avail_term_ops_true {cur : Pion.Array Bool} {t : Term} (h : avail_term_ops cur t = ok true) :
    AvailTerm (fun t => cur.val[t]? = some true) t := by
  unfold avail_term_ops at h
  cases t with
  | Jnz a _ _ => simp only at h; exact avail_atom_true (by obtain ⟨x, hx, h⟩ := bind_eq_ok h; cases ok_inj' h; exact hx)
  | Ret hh _ a =>
    simp only at h
    intro hht
    subst hht
    simp only [Bool.not_true, Bool.false_eq_true, ↓reduceIte] at h
    exact avail_atom_true (by obtain ⟨x, hx, h⟩ := bind_eq_ok h; cases ok_inj' h; exact hx)
  | _ => trivial

theorem i32_mul0_add (nt x : Std.I32) : Pion.I32.add (Pion.I32.mul (i32n 0) nt) x = x := by
  apply i32_ext'
  simp [i32n, Std.I32.wrapping_add_bv_eq, Std.I32.wrapping_mul_bv_eq]

/-- `cur` starts as the temps available at the entry of block `bI`. -/
theorem avail_loop5 {nt : Std.I32} {av : Pion.Array Bool} {bI : Std.I32} :
    ∀ (x : Std.I32 × Pion.Array Bool) r, check_avail_loop5 nt av bI x.1 x.2 = ok r →
      (0 ≤ x.1.val ∧ ∀ y : Nat, x.2.val[y]? = some true →
        av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true) →
      (r.2.val.length = x.2.val.length ∧ ∀ y : Nat, r.2.val[y]? = some true →
        av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true) := by
  intro x r h hx
  unfold check_avail_loop5 at h
  refine loop_ok_inv (fun (x : Std.I32 × Pion.Array Bool) =>
      match x with | (y, cur) => check_avail_loop5.body nt av bI y cur)
    (fun (y : Std.I32 × Pion.Array Bool) => 0 ≤ y.1.val ∧ y.2.val.length = x.2.val.length ∧
      ∀ z : Nat, y.2.val[z]? = some true → av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n z)) = ok true)
    (fun (r : Std.I32 × Pion.Array Bool) => r.2.val.length = x.2.val.length ∧
      ∀ z : Nat, r.2.val[z]? = some true → av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n z)) = ok true)
    ?_ x r h ⟨hx.1, rfl, hx.2⟩
  rintro ⟨y, cur⟩ c ⟨hy0, hl, hall⟩ hc
  simp only at hy0 hl hall hc
  unfold check_avail_loop5.body at hc
  split at hc
  · rename_i hlt
    have hys := i32_succ_val hlt
    try simp only at hc
    obtain ⟨v, hv, hc⟩ := bind_eq_ok hc
    obtain ⟨c1, hc1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    dsimp only
    have hc1' := arr_set_ok hc1
    refine ⟨by omega, by rw [hc1', List.length_set, hl], fun z hz => ?_⟩
    rw [hc1', List.getElem?_set] at hz
    split at hz
    · rename_i e
      split at hz
      · cases hz
        rw [i32n_of_val hy0] at hv
        rw [← e]; exact hv
      · cases hz
    · exact hall z hz
  · rw [← ok_inj' hc]; exact ⟨hl, hall⟩

/-- Then the phi destinations of the block. -/
theorem avail_loop6 {phis : Pion.Array Phi} (P0 : Nat → Prop) :
    ∀ (x : Std.I32 × Pion.Array Bool) r, check_avail_loop6 phis x.1 x.2 = ok r →
      (0 ≤ x.1.val ∧ ∀ t : Nat, x.2.val[t]? = some true → P0 t ∨ ∃ P ∈ phis.val, P.dst.val = t) →
      (r.2.val.length = x.2.val.length ∧
        (∀ t : Nat, r.2.val[t]? = some true → P0 t ∨ ∃ P ∈ phis.val, P.dst.val = t) ∧
        ∀ k, x.1.val.toNat ≤ k → ∀ hk : k < phis.val.length, 0 ≤ phis.val[k].dst.val ∧
          phis.val[k].dst.val < x.2.val.length) := by
  intro x r h hx
  unfold check_avail_loop6 at h
  refine loop_ok_inv (fun (x : Std.I32 × Pion.Array Bool) =>
      match x with | (i, cur) => check_avail_loop6.body phis i cur)
    (fun (y : Std.I32 × Pion.Array Bool) => 0 ≤ y.1.val ∧ x.1.val ≤ y.1.val ∧ y.2.val.length = x.2.val.length ∧
      (∀ t : Nat, y.2.val[t]? = some true → P0 t ∨ ∃ P ∈ phis.val, P.dst.val = t) ∧
      ∀ k, x.1.val.toNat ≤ k → k < y.1.val.toNat → ∀ hk : k < phis.val.length,
        0 ≤ phis.val[k].dst.val ∧ phis.val[k].dst.val < x.2.val.length)
    (fun (r : Std.I32 × Pion.Array Bool) => r.2.val.length = x.2.val.length ∧
      (∀ t : Nat, r.2.val[t]? = some true → P0 t ∨ ∃ P ∈ phis.val, P.dst.val = t) ∧
      ∀ k, x.1.val.toNat ≤ k → ∀ hk : k < phis.val.length, 0 ≤ phis.val[k].dst.val ∧
        phis.val[k].dst.val < x.2.val.length)
    ?_ x r h ⟨hx.1, le_refl _, rfl, hx.2, fun k h1 h2 => by omega⟩
  rintro ⟨i, cur⟩ c ⟨hi0, hii, hl, hall, hdst⟩ hc
  simp only at hi0 hii hl hall hdst hc
  unfold check_avail_loop6.body at hc
  obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
  obtain ⟨ht1, ht2⟩ := arr_length_ok ht
  split at hc
  · rename_i hlt
    simp only [i32_lt_iff, ht1] at hlt
    have his := i32_succ_val' hlt ht2
    obtain ⟨P, hP, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hPl, hPv⟩ := arr_get_ok hP
    try simp only at hc
    obtain ⟨c1, hc1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    dsimp only
    have hc1' := arr_set_ok hc1
    have hin : 0 ≤ P.dst.val ∧ P.dst.val < cur.val.length := by
      unfold Pion.Array.set listSet at hc1
      split at hc1
      · rename_i hb; simp only [inBounds] at hb; exact hb
      · simp at hc1
    refine ⟨by omega, by omega, by rw [hc1', List.length_set, hl], fun t' ht' => ?_, fun k h1 h2 hk => ?_⟩
    · rw [hc1', List.getElem?_set] at ht'
      split at ht'
      · rename_i e
        right
        refine ⟨P, by rw [← hPv]; exact List.getElem_mem _, ?_⟩
        omega
      · exact hall t' ht'
    · by_cases hki : k = i.val.toNat
      · subst hki
        rw [hPv, ← hl]; exact hin
      · exact hdst k h1 (by omega) hk
  · rename_i hge
    simp only [i32_lt_iff, ht1, not_lt] at hge
    rw [← ok_inj' hc]
    exact ⟨hl, hall, fun k h1 hk => hdst k h1 (by omega) hk⟩

theorem b1_ne0 {b : Std.I32} (h0 : 0 ≤ b.val) (h1 : b.val < 2147483647) : Pion.I32.add b 1#i32 ≠ 0#i32 := by
  intro he
  have := congrArg (·.val) he
  simp only [i32_zero_val] at this
  rw [i32_succ_val' (m := 2147483647) h1 (le_refl _)] at this
  omega

/-- The instructions of the block read only initialised temps. -/
theorem avail_loop7 {insts : Pion.Array Inst} {bI : Std.I32} (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647)
    (P1 : Nat → Prop) (n0 : Nat) :
    ∀ (x : Std.I32 × Pion.Array Bool) r, check_avail_loop7 insts bI x.1 x.2 = ok r → x.1 = 0#i32 →
      x.2.val.length = n0 → (∀ t : Nat, x.2.val[t]? = some true → P1 t) →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr y => (∀ k, ∀ hk : k < insts.val.length,
            AvailInst (fun t => t < n0 ∧ (P1 t ∨ ∃ k' < k, ∃ hk' : k' < insts.val.length,
              (instDst insts.val[k']).val = t)) insts.val[k] ∧
            (0 ≤ (instDst insts.val[k]).val → (instDst insts.val[k]).val < n0)) ∧
          ∀ t : Nat, y.2.val[t]? = some true → t < n0 ∧ (P1 t ∨ ∃ k' < insts.val.length,
            ∃ hk' : k' < insts.val.length, (instDst insts.val[k']).val = t) := by
  intro x r h hx0 hxl hx
  unfold check_avail_loop7 at h
  refine loop_ok_inv (fun (x : Std.I32 × Pion.Array Bool) =>
      match x with | (i, cur) => check_avail_loop7.body insts bI i cur)
    (fun (y : Std.I32 × Pion.Array Bool) => 0 ≤ y.1.val ∧ y.2.val.length = n0 ∧
      (∀ t : Nat, y.2.val[t]? = some true → P1 t ∨ ∃ k' < y.1.val.toNat, ∃ hk' : k' < insts.val.length,
        (instDst insts.val[k']).val = t) ∧
      ∀ k, k < y.1.val.toNat → ∀ hk : k < insts.val.length,
        AvailInst (fun t => t < n0 ∧ (P1 t ∨ ∃ k' < k, ∃ hk' : k' < insts.val.length,
          (instDst insts.val[k']).val = t)) insts.val[k] ∧
        (0 ≤ (instDst insts.val[k]).val → (instDst insts.val[k]).val < n0))
    (fun (r : Sum Std.I32 (Std.I32 × Pion.Array Bool)) => match r with
      | .inl e => e ≠ 0#i32
      | .inr y => (∀ k, ∀ hk : k < insts.val.length,
            AvailInst (fun t => t < n0 ∧ (P1 t ∨ ∃ k' < k, ∃ hk' : k' < insts.val.length,
              (instDst insts.val[k']).val = t)) insts.val[k] ∧
            (0 ≤ (instDst insts.val[k]).val → (instDst insts.val[k]).val < n0)) ∧
          ∀ t : Nat, y.2.val[t]? = some true → t < n0 ∧ (P1 t ∨ ∃ k' < insts.val.length,
            ∃ hk' : k' < insts.val.length, (instDst insts.val[k']).val = t))
    ?_ x r h ⟨by rw [hx0]; simp, hxl, fun t ht => Or.inl (hx t ht), fun k hk => by rw [hx0] at hk; simp at hk⟩
  rintro ⟨i, cur⟩ c ⟨hi0, hl, hall, hdone⟩ hc
  simp only at hi0 hl hall hdone hc
  unfold check_avail_loop7.body at hc
  obtain ⟨t, ht, hc⟩ := bind_eq_ok hc
  obtain ⟨ht1, ht2⟩ := arr_length_ok ht
  have hcurlt : ∀ t : Nat, cur.val[t]? = some true → t < n0 := by
    intro t' h'
    by_contra hc'
    rw [List.getElem?_eq_none (by omega)] at h'
    cases h'
  split at hc
  · rename_i hlt
    simp only [i32_lt_iff, ht1] at hlt
    have his := i32_succ_val' hlt ht2
    obtain ⟨inst, hinst, hc⟩ := bind_eq_ok hc
    obtain ⟨_, hil, hiv⟩ := arr_get_ok hinst
    obtain ⟨t30, ht30, hc⟩ := bind_eq_ok hc
    split at hc
    · rw [← ok_inj' hc]; exact b1_ne0 hb0 hb1
    rename_i h30
    have h30t : t30 = true := by cases t30 <;> simp_all
    rw [h30t] at ht30
    have havail := avail_inst_ops_true ht30
    simp only [inst_dst_spec, bind_ok] at hc
    obtain ⟨c1, hc1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    dsimp only
    -- the destination
    have hc1p : c1.val.length = n0 ∧ (0 ≤ (instDst inst).val → (instDst inst).val < n0) ∧
        ∀ t' : Nat, c1.val[t']? = some true → cur.val[t']? = some true ∨ (instDst inst).val = t' := by
      split at hc1
      · rename_i hd
        obtain ⟨c2, hc2, hc1⟩ := bind_eq_ok hc1
        cases ok_inj' hc1
        have hc2' := arr_set_ok hc2
        have hin : 0 ≤ (instDst inst).val ∧ (instDst inst).val < cur.val.length := by
          unfold Pion.Array.set listSet at hc2
          split at hc2
          · rename_i hb; simp only [inBounds] at hb; exact hb
          · simp at hc2
        refine ⟨by rw [hc2', List.length_set, hl], fun _ => by omega, fun t' ht' => ?_⟩
        rw [hc2', List.getElem?_set] at ht'
        split at ht'
        · right; omega
        · left; exact ht'
      · rename_i hd
        cases ok_inj' hc1
        refine ⟨hl, fun h' => absurd (by simpa [i32_le_iff] using h') hd, fun t' ht' => Or.inl ht'⟩
    obtain ⟨hc1l, hc1d, hc1t⟩ := hc1p
    refine ⟨by omega, hc1l, fun t' ht' => ?_, fun k hk hk' => ?_⟩
    · rcases hc1t t' ht' with h' | h'
      · rcases hall t' h' with h'' | ⟨k', hk', hk'', he⟩
        · exact Or.inl h''
        · exact Or.inr ⟨k', by omega, hk'', he⟩
      · exact Or.inr ⟨i.val.toNat, by omega, hil, by rw [hiv]; exact h'⟩
    · by_cases hki : k = i.val.toNat
      · subst hki
        rw [hiv]
        refine ⟨?_, hc1d⟩
        cases inst with
        | Par _ _ _ => trivial
        | Un _ _ _ a =>
          simp only [AvailInst]
          exact availAtom_mono (cur := fun t => cur.val[t]? = some true)
            (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail
        | Bin _ _ _ a b =>
          exact ⟨availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail.1,
            availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail.2⟩
        | Load _ _ _ _ a =>
          simp only [AvailInst]
          exact availAtom_mono (cur := fun t => cur.val[t]? = some true)
            (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail
        | Store _ v a =>
          exact ⟨availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail.1,
            availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail.2⟩
        | Call _ _ _ c args =>
          exact ⟨availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) havail.1,
            fun y hy => availAtom_mono (fun t' h' => ⟨hcurlt t' h', hall t' h'⟩) (havail.2 y hy)⟩
        | Alloc _ _ _ => trivial
      · exact hdone k (by omega) hk'
  · rename_i hge
    simp only [i32_lt_iff, ht1, not_lt] at hge
    rw [← ok_inj' hc]
    refine ⟨fun k hk => hdone k (by omega) hk, fun t' ht' => ⟨hcurlt t' ht', ?_⟩⟩
    rcases hall t' ht' with h' | ⟨k', hk', hk'', he⟩
    · exact Or.inl h'
    · exact Or.inr ⟨k', hk'', hk'', he⟩

/-- Every temp available at a successor's entry is initialised at the end of the block. -/
theorem avail_loop9 {nt : Std.I32} {av : Pion.Array Bool} {sI : Std.I32} {cur : Pion.Array Bool}
    {bI : Std.I32} (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647) :
    ∀ z r, check_avail_loop9 nt av sI cur bI z = ok r → z = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ y : Nat, y < nt.val.toNat →
          av.get (Pion.I32.add (Pion.I32.mul sI nt) (i32n y)) = ok true → cur.val[y]? = some true := by
  intro z r h hz
  unfold check_avail_loop9 at h
  have key := scan_loop (fun z => check_avail_loop9.body nt av sI cur bI z) nt.val.toNat
    (fun y => av.get (Pion.I32.add (Pion.I32.mul sI nt) (i32n y)) = ok true → cur.val[y]? = some true)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro i c hi hc
      unfold check_avail_loop9.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < nt.val.toNat := by simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := i32_val_le nt; omega, ?_⟩
        obtain ⟨t38, ht38, hc⟩ := bind_eq_ok hc
        obtain ⟨t40, ht40, hc⟩ := bind_eq_ok hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, b1_ne0 hb0 hb1⟩
        · rename_i h40
          right
          refine ⟨fun hav => ?_, (ok_inj' hc).symm⟩
          rw [← i32n_of_val hi] at hav
          rw [hav] at ht38
          cases ok_inj' ht38
          simp only [↓reduceIte] at ht40
          obtain ⟨t39, ht39, ht40⟩ := bind_eq_ok ht40
          cases ok_inj' ht40
          obtain ⟨_, h39l, h39v⟩ := arr_get_ok ht39
          rw [List.getElem?_eq_getElem h39l, h39v]
          cases t39 <;> simp_all
      · rename_i hge
        right
        exact ⟨by simp only [i32_lt_iff] at hge; omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key z r h (by rw [hz]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hk; exact he
  | inr g => exact fun y hy hav => hk.2 y (by rw [hz]; simp) hy hav

/-- Every phi of a successor has an argument on the edge, initialised at the end of the block. -/
theorem avail_loop10 {np : Std.I32} {f : Func} {sI bI : Std.I32} {cur : Pion.Array Bool}
    (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647) (S : Block) (_hs0 : 0 ≤ sI.val)
    (hS : f.blocks.val[sI.val.toNat]? = some S) (hnp : np.val = S.phis.val.length) :
    ∀ q r, check_avail_loop10 np f sI bI cur q = ok r → q = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ P ∈ S.phis.val, ∃ a, phiArg P bI.val.toNat = some a ∧
          AvailAtom (fun t => cur.val[t]? = some true) a := by
  intro q r h hq
  unfold check_avail_loop10 at h
  have key := scan_loop (fun q => check_avail_loop10.body np f sI bI cur q) S.phis.val.length
    (fun q => ∀ hq : q < S.phis.val.length, ∃ a, phiArg S.phis.val[q] bI.val.toNat = some a ∧
      AvailAtom (fun t => cur.val[t]? = some true) a)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro i c hi hc
      unfold check_avail_loop10.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < S.phis.val.length := by simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := i32_val_le np; omega, ?_⟩
        obtain ⟨ai, hai, hc⟩ := bind_eq_ok hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, b1_ne0 hb0 hb1⟩
        rename_i hai0
        have hai0' : 0 ≤ ai.val := by simpa [i32_lt_iff] using hai0
        obtain ⟨B1, hB1, hc⟩ := bind_eq_ok hc
        obtain ⟨P1, hP1, hc⟩ := bind_eq_ok hc
        obtain ⟨A1, hA1, hc⟩ := bind_eq_ok hc
        obtain ⟨t47, ht47, hc⟩ := bind_eq_ok hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, b1_ne0 hb0 hb1⟩
        rename_i h47
        right
        refine ⟨fun hq => ?_, (ok_inj' hc).symm⟩
        obtain ⟨B, P, -, hB, -, hP, hcase⟩ := phi_arm_index_spec hai
        have hBS : S = B := by rw [hS] at hB; exact Option.some.inj hB
        subst hBS
        rcases hcase with ⟨-, hr, hpred, hfirst⟩ | ⟨hm1, -⟩
        · obtain ⟨_, hB1l, hB1v⟩ := arr_get_ok hB1
          have hB1' : S = B1 := by
            have h' := hS
            rw [List.getElem?_eq_getElem hB1l, hB1v] at h'
            exact (Option.some.inj h').symm
          subst hB1'
          obtain ⟨_, hP1l, hP1v⟩ := arr_get_ok hP1
          have hP1' : P = P1 := by
            have h' := hP
            rw [List.getElem?_eq_getElem hP1l, hP1v] at h'
            exact (Option.some.inj h').symm
          subst hP1'
          have hPq : S.phis.val[i.val.toNat] = P := by
            rw [List.getElem?_eq_getElem hP1l] at hP; exact Option.some.inj hP
          obtain ⟨_, hA1l, hA1v⟩ := arr_get_ok hA1
          have h47t : t47 = true := by cases t47 <;> simp_all
          rw [h47t] at ht47
          refine ⟨A1.value, ?_, by rw [← hA1v] at ht47 ⊢; exact avail_atom_true ht47⟩
          rw [hPq, ← hA1v]
          exact phiArg_of_index hA1l (by rw [hpred]; omega)
            (fun j hj hj' => by have := hfirst j hj hj'; intro hc'; exact this (i32_ext (by omega)))
        · exact absurd hm1 (by omega)
      · rename_i hge
        right
        exact ⟨by simp only [i32_lt_iff] at hge; omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key q r h (by rw [hq]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hk; exact he
  | inr g =>
    intro P hP
    obtain ⟨k, hkl, rfl⟩ := List.getElem_of_mem hP
    exact hk.2 k (by rw [hq]; simp) hkl hkl

/-- The successors of the block. -/
theorem avail_loop8 {n : Std.I32} {tm : Term} {nb bI nt : Std.I32} {av cur : Pion.Array Bool} {f : Func}
    (hn : n.val = (termSuccs tm).length) (hnb : nb.val = f.blocks.val.length)
    (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647) :
    ∀ k r, check_avail_loop8 n tm nb bI nt av cur f k = ok r → k = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ s ∈ termSuccs tm, 0 < s.val ∧ s.val < f.blocks.val.length ∧
          (∀ y : Nat, y < nt.val.toNat → av.get (Pion.I32.add (Pion.I32.mul s nt) (i32n y)) = ok true →
            cur.val[y]? = some true) ∧
          ∃ S, f.blocks.val[s.val.toNat]? = some S ∧ ∀ P ∈ S.phis.val, ∃ a, phiArg P bI.val.toNat = some a ∧
            AvailAtom (fun t => cur.val[t]? = some true) a := by
  intro k r h hk
  unfold check_avail_loop8 at h
  have key := scan_loop (fun k => check_avail_loop8.body n tm nb bI nt av cur f k) (termSuccs tm).length
    (fun k => ∀ hk : k < (termSuccs tm).length, 0 < ((termSuccs tm)[k]).val ∧
      ((termSuccs tm)[k]).val < f.blocks.val.length ∧
      (∀ y : Nat, y < nt.val.toNat → av.get (Pion.I32.add (Pion.I32.mul (termSuccs tm)[k] nt) (i32n y)) = ok true →
        cur.val[y]? = some true) ∧
      ∃ S, f.blocks.val[((termSuccs tm)[k]).val.toNat]? = some S ∧ ∀ P ∈ S.phis.val, ∃ a,
        phiArg P bI.val.toNat = some a ∧ AvailAtom (fun t => cur.val[t]? = some true) a)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro i c hi hc
      unfold check_avail_loop8.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < (termSuccs tm).length := by simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := termSuccs_len tm; omega, ?_⟩
        rw [term_succ_spec tm i hi hlt'] at hc
        simp only [bind_ok] at hc
        generalize hsk : (termSuccs tm)[i.val.toNat] = sk at hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, b1_ne0 hb0 hb1⟩
        rename_i hrange
        simp only [Bool.or_eq_true, decide_eq_true_eq, not_or, not_le, i32_le_iff,
          i32_zero_val, hnb] at hrange
        obtain ⟨s9, hs9, hc⟩ := bind_eq_ok hc
        have h9 := avail_loop9 hb0 hb1 _ s9 hs9 rfl
        cases s9 with
        | inl e => simp only at hc; left; exact ⟨_, (ok_inj' hc).symm, h9⟩
        | inr z1 =>
          simp only at hc
          obtain ⟨S, hS, hc⟩ := bind_eq_ok hc
          obtain ⟨_, hSl, hSv⟩ := arr_get_ok hS
          obtain ⟨np, hnp, hc⟩ := bind_eq_ok hc
          obtain ⟨hnp1, -⟩ := arr_length_ok hnp
          obtain ⟨s10, hs10, hc⟩ := bind_eq_ok hc
          have hS' : f.blocks.val[sk.val.toNat]? = some S := by rw [List.getElem?_eq_getElem hSl, hSv]
          have h10 := avail_loop10 hb0 hb1 S (by omega) hS' hnp1 _ s10 hs10 rfl
          cases s10 with
          | inl e => simp only at hc; left; exact ⟨_, (ok_inj' hc).symm, h10⟩
          | inr q1 =>
            simp only at hc
            right
            refine ⟨fun hk' => ?_, (ok_inj' hc).symm⟩
            rw [hsk]
            exact ⟨by omega, by omega, h9, S, hS', h10⟩
      · rename_i hge
        right
        exact ⟨by simp only [i32_lt_iff] at hge; omega, _, (ok_inj' hc).symm, trivial⟩)
  have hkk := key k r h (by rw [hk]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hkk; exact he
  | inr g =>
    intro s hs
    obtain ⟨j, hjl, rfl⟩ := List.getElem_of_mem hs
    exact hkk.2 j (by rw [hk]; simp) hjl hjl

theorem availInst_mono {cur cur' : Nat → Prop} (hm : ∀ t, cur t → cur' t) {i : Inst}
    (h : AvailInst cur i) : AvailInst cur' i := by
  cases i with
  | Par _ _ _ => trivial
  | Un _ _ _ a => exact availAtom_mono (cur := cur) hm h
  | Bin _ _ _ a b => exact ⟨availAtom_mono hm h.1, availAtom_mono hm h.2⟩
  | Load _ _ _ _ a => exact availAtom_mono (cur := cur) hm h
  | Store _ v a => exact ⟨availAtom_mono hm h.1, availAtom_mono hm h.2⟩
  | Call _ _ _ c args => exact ⟨availAtom_mono hm h.1, fun y hy => availAtom_mono hm (h.2 y hy)⟩
  | Alloc _ _ _ => trivial

theorem availTerm_mono {cur cur' : Nat → Prop} (hm : ∀ t, cur t → cur' t) {t : Term}
    (h : AvailTerm cur t) : AvailTerm cur' t := by
  cases t with
  | Jnz a _ _ => exact availAtom_mono (cur := cur) hm h
  | Ret hh _ a => exact fun e => availAtom_mono hm (h e)
  | _ => trivial

/-- The blocks whose values must not be mentioned at the entry of `b` (`bm`). -/
theorem avail_loop2 {bm_t bm_s : Pion.Array Std.I32} {bI : Std.I32} :
    ∀ (x : Std.I32 × Pion.Array Std.I32) r, check_avail_loop2 bm_t bm_s bI x.1 x.2 = ok r → x.1 = 0#i32 →
      ∀ (j : Nat) (sb : Std.I32), bm_t.val[j]? = some bI → bm_s.val[j]? = some sb → sb ∈ r.2.val := by
  intro x r h hx0
  unfold check_avail_loop2 at h
  refine loop_ok_inv (fun (x : Std.I32 × Pion.Array Std.I32) =>
      match x with | (j, xs) => check_avail_loop2.body bm_t bm_s bI j xs)
    (fun (y : Std.I32 × Pion.Array Std.I32) => 0 ≤ y.1.val ∧
      ∀ (j : Nat) (sb : Std.I32), j < y.1.val.toNat → bm_t.val[j]? = some bI → bm_s.val[j]? = some sb →
        sb ∈ y.2.val)
    (fun (r : Std.I32 × Pion.Array Std.I32) =>
      ∀ (j : Nat) (sb : Std.I32), bm_t.val[j]? = some bI → bm_s.val[j]? = some sb → sb ∈ r.2.val)
    ?_ x r h ⟨by rw [hx0]; simp, fun j sb hj => by rw [hx0] at hj; simp at hj⟩
  rintro ⟨j, xs⟩ c ⟨hj0, hall⟩ hc
  simp only at hj0 hall hc
  unfold check_avail_loop2.body at hc
  obtain ⟨n5, hn5, hc⟩ := bind_eq_ok hc
  obtain ⟨hn51, hn52⟩ := arr_length_ok hn5
  obtain ⟨t7, ht7, hc⟩ := bind_eq_ok hc
  split at hc
  · rename_i h7
    have hjl : j.val < bm_t.val.length ∧ j.val < bm_s.val.length := by
      split at ht7
      · rename_i hlt
        obtain ⟨n6, hn6, ht7⟩ := bind_eq_ok ht7
        obtain ⟨hn61, -⟩ := arr_length_ok hn6
        cases ok_inj' ht7
        simp only [decide_eq_true_eq, i32_lt_iff] at h7
        simp only [i32_lt_iff] at hlt
        omega
      · cases ok_inj' ht7; cases h7
    have hjs := i32_succ_val' hjl.1 hn52
    obtain ⟨t8, ht8, hc⟩ := bind_eq_ok hc
    obtain ⟨_, ht8l, ht8v⟩ := arr_get_ok ht8
    obtain ⟨t11, ht11, hc⟩ := bind_eq_ok hc
    obtain ⟨xs1, hxs1, hc⟩ := bind_eq_ok hc
    rw [← ok_inj' hc]
    dsimp only
    have hsub : ∀ y, y ∈ xs.val → y ∈ xs1.val := by
      intro y hy
      split at hxs1
      · obtain ⟨t12, -, hxs1⟩ := bind_eq_ok hxs1
        cases ok_inj' hxs1
        simp [hy]
      · cases ok_inj' hxs1; exact hy
    refine ⟨by omega, fun j' sb hj' hbt hbs => ?_⟩
    by_cases hjj : j' = j.val.toNat
    · subst hjj
      rw [List.getElem?_eq_getElem ht8l, ht8v] at hbt
      cases hbt
      simp only [↓reduceIte] at ht11
      obtain ⟨t9, ht9, ht11⟩ := bind_eq_ok ht11
      obtain ⟨_, ht9l, ht9v⟩ := arr_get_ok ht9
      have hsb : t9 = sb := by rw [List.getElem?_eq_getElem ht9l, ht9v] at hbs; exact Option.some.inj hbs
      subst hsb
      obtain ⟨t10, ht10, ht11⟩ := bind_eq_ok ht11
      cases ok_inj' ht11
      cases t10 with
      | true => exact hsub _ ((contains_int_spec ht10).1 rfl)
      | false =>
        simp only [Bool.not_false, ↓reduceIte] at hxs1
        obtain ⟨t12, ht12, hxs1⟩ := bind_eq_ok hxs1
        cases ok_inj' hxs1
        rw [ht9] at ht12
        cases ok_inj' ht12
        simp
    · exact hsub _ (hall j' sb (by omega) hbt hbs)
  · rename_i h7
    rw [← ok_inj' hc]
    intro j' sb hbt hbs
    by_cases hj' : j' < j.val.toNat
    · exact hall j' sb hj' hbt hbs
    · exfalso
      have hlen : bm_t.val.length ≤ j' ∨ bm_s.val.length ≤ j' := by
        split at ht7
        · rename_i hlt
          obtain ⟨n6, hn6, ht7⟩ := bind_eq_ok ht7
          obtain ⟨hn61, -⟩ := arr_length_ok hn6
          cases ok_inj' ht7
          simp only [decide_eq_true_eq, i32_lt_iff, not_lt] at h7
          right; omega
        · rename_i hlt
          simp only [i32_lt_iff, not_lt] at hlt
          left; omega
      rcases hlen with hl | hl
      · rw [List.getElem?_eq_none hl] at hbt; cases hbt
      · rw [List.getElem?_eq_none hl] at hbs; cases hbs

/-- For one block `sb` (its mention table `m`): no temp available at the entry of `b` depends on
`sb`. -/
theorem avail_loop4 {nt : Std.I32} {av : Pion.Array Bool} {bI : Std.I32} {vids : Pion.Array Std.I32}
    {m : Pion.Array Bool} {vg : ValGraph} {sb : Std.I32} (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647)
    (hm : m.val.length = vg.nodes.val.length ∧ ∀ i, m.val[i]? = some false → Indep vg sb i) :
    ∀ x r, check_avail_loop4 nt av bI vids m x = ok r → x = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ y : Nat, y < nt.val.toNat → av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true →
          ∀ v, vids.val[y]? = some v → 0 ≤ v.val → Valid vg v ∧ Indep vg sb v.val.toNat := by
  intro x r h hx
  unfold check_avail_loop4 at h
  have key := scan_loop (fun x => check_avail_loop4.body nt av bI vids m x) nt.val.toNat
    (fun y => av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true →
      ∀ v, vids.val[y]? = some v → 0 ≤ v.val → Valid vg v ∧ Indep vg sb v.val.toNat)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro i c hi hc
      unfold check_avail_loop4.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < nt.val.toNat := by simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := i32_val_le nt; omega, ?_⟩
        obtain ⟨t15, ht15, hc⟩ := bind_eq_ok hc
        obtain ⟨t17, ht17, hc⟩ := bind_eq_ok hc
        obtain ⟨t23, ht23, hc⟩ := bind_eq_ok hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, b1_ne0 hb0 hb1⟩
        · rename_i h23
          right
          refine ⟨fun hav v hv hv0 => ?_, (ok_inj' hc).symm⟩
          rw [← i32n_of_val hi] at hav
          rw [hav] at ht15
          cases ok_inj' ht15
          simp only [↓reduceIte] at ht17
          obtain ⟨w, hw, ht17⟩ := bind_eq_ok ht17
          obtain ⟨_, hwl, hwv⟩ := arr_get_ok hw
          have hwv' : w = v := by rw [List.getElem?_eq_getElem hwl, hwv] at hv; exact Option.some.inj hv
          subst hwv'
          cases ok_inj' ht17
          have h17 : decide (w >= 0#i32) = true := by simpa [i32_le_iff] using hv0
          rw [h17] at ht23
          simp only [↓reduceIte] at ht23
          obtain ⟨w2, hw2, ht23⟩ := bind_eq_ok ht23
          rw [hw] at hw2
          cases ok_inj' hw2
          obtain ⟨len, hlen, ht23⟩ := bind_eq_ok ht23
          obtain ⟨hlen1, -⟩ := arr_length_ok hlen
          split at ht23
          · cases ok_inj' ht23
            exact absurd rfl h23
          · rename_i hge
            obtain ⟨w3, hw3, ht23⟩ := bind_eq_ok ht23
            rw [hw] at hw3
            cases ok_inj' hw3
            obtain ⟨t21, ht21, ht23⟩ := bind_eq_ok ht23
            cases ok_inj' ht23
            obtain ⟨_, h21l, h21v⟩ := arr_get_ok ht21
            have hlt2 : w.val.toNat < m.val.length := by
              simp only [ge_iff_le, i32_le_iff, not_le] at hge
              omega
            have hf : m.val[w.val.toNat]? = some false := by
              rw [List.getElem?_eq_getElem h21l, h21v]
              cases t23
              · rfl
              · exact absurd rfl h23
            exact ⟨⟨hv0, by rw [← hm.1]; exact hlt2⟩, hm.2 _ hf⟩
      · rename_i hge
        right
        exact ⟨by simp only [i32_lt_iff] at hge; omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key x r h (by rw [hx]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hk; exact he
  | inr g => exact fun y hy hav => hk.2 y (by rw [hx]; simp) hy hav

/-- No temp available at the entry of `b` depends on a block of `xs`. -/
theorem avail_loop3 {nt : Std.I32} {av : Pion.Array Bool} {bI : Std.I32} {vids : Pion.Array Std.I32}
    {xs : Pion.Array Std.I32} {vg : ValGraph} (hb0 : 0 ≤ bI.val) (hb1 : bI.val < 2147483647) :
    ∀ i r, check_avail_loop3 xs vg nt av bI vids i = ok r → i = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ sb ∈ xs.val, ∀ y : Nat, y < nt.val.toNat →
          av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true →
          ∀ v, vids.val[y]? = some v → 0 ≤ v.val → Valid vg v ∧ Indep vg sb v.val.toNat := by
  intro i0 r h hi
  unfold check_avail_loop3 at h
  have key := scan_loop (fun i => check_avail_loop3.body xs vg nt av bI vids i) xs.val.length
    (fun k => ∀ hk : k < xs.val.length, ∀ y : Nat, y < nt.val.toNat →
      av.get (Pion.I32.add (Pion.I32.mul bI nt) (i32n y)) = ok true →
      ∀ v, vids.val[y]? = some v → 0 ≤ v.val → Valid vg v ∧ Indep vg xs.val[k] v.val.toNat)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro j c hj hc
      unfold check_avail_loop3.body at hc
      obtain ⟨n13, hn13, hc⟩ := bind_eq_ok hc
      obtain ⟨hn131, hn132⟩ := arr_length_ok hn13
      split at hc
      · rename_i hlt
        simp only [i32_lt_iff, hn131] at hlt
        left
        refine ⟨hlt, hn132, ?_⟩
        obtain ⟨sb, hsb, hc⟩ := bind_eq_ok hc
        obtain ⟨_, hsbl, hsbv⟩ := arr_get_ok hsb
        obtain ⟨m, hm, hc⟩ := bind_eq_ok hc
        obtain ⟨s4, hs4, hc⟩ := bind_eq_ok hc
        have h4 := avail_loop4 hb0 hb1 (blk_mentions_table_sound hm) _ s4 hs4 rfl
        cases s4 with
        | inl e =>
          simp only at hc
          left
          exact ⟨_, (ok_inj' hc).symm, h4⟩
        | inr _ =>
          simp only at hc
          right
          refine ⟨fun hk => ?_, (ok_inj' hc).symm⟩
          simp only [hsbv]
          exact h4
      · rename_i hge
        simp only [i32_lt_iff, hn131, not_lt] at hge
        right
        exact ⟨hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key i0 r h (by rw [hi]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hk; exact he
  | inr g =>
    intro sb hsb
    obtain ⟨k, hkl, rfl⟩ := List.getElem_of_mem hsb
    exact hk.2 k (by rw [hi]; simp) hkl hkl

/-- No temp is available at the entry of the function. -/
theorem avail_loop0 {nt : Std.I32} {av : Pion.Array Bool} :
    ∀ t r, check_avail_loop0 nt av t = ok r → t = 0#i32 →
      match r with
      | .inl e => e ≠ 0#i32
      | .inr _ => ∀ y : Nat, y < nt.val.toNat → av.get (i32n y) = ok false := by
  intro t r h ht
  unfold check_avail_loop0 at h
  have key := scan_loop (fun t => check_avail_loop0.body nt av t) nt.val.toNat
    (fun y => av.get (i32n y) = ok false) (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro i c hi hc
      unfold check_avail_loop0.body at hc
      split at hc
      · rename_i hlt
        have hlt' : i.val < nt.val.toNat := by simp only [i32_lt_iff] at hlt; omega
        left
        refine ⟨hlt', by have := i32_val_le nt; omega, ?_⟩
        obtain ⟨t3, ht3, hc⟩ := bind_eq_ok hc
        split at hc
        · left; exact ⟨_, (ok_inj' hc).symm, by decide⟩
        · rename_i h3
          right
          refine ⟨?_, (ok_inj' hc).symm⟩
          rw [← i32n_of_val hi]
          have : t3 = false := by cases t3 <;> simp_all
          rw [← this]; exact ht3
      · rename_i hge
        right
        exact ⟨by simp only [i32_lt_iff] at hge; omega, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key t r h (by rw [ht]; simp)
  cases r with
  | inl e => obtain ⟨_, _, _, he, _⟩ := hk; exact he
  | inr g => exact fun y hy => hk.2 y (by rw [ht]; simp) hy

/-- What `check_avail` certifies about one reachable block `b`. -/
def AvailBlock (vg : ValGraph) (f : Func) (info : FnInfo) (av : Pion.Array Bool)
    (vids : List Std.I32) (bm_t bm_s : List Std.I32) (b : Nat) : Prop :=
  (∀ (j : Nat) (sb : Std.I32), bm_t[j]? = some (i32n b) → bm_s[j]? = some sb →
    ∀ x, x < info.nt.val.toNat → AvB av info.nt b x → ∀ v, vids[x]? = some v → 0 ≤ v.val →
      Valid vg v ∧ Indep vg sb v.val.toNat) ∧
  ∀ (B : Block), f.blocks.val[b]? = some B →
    (∀ P ∈ B.phis.val, 0 ≤ P.dst.val ∧ P.dst.val < info.nt.val) ∧
    (∀ i (hi : i < B.insts.val.length),
      AvailInst (CurAt info.nt.val.toNat (AvB av info.nt b) B i) B.insts.val[i] ∧
      (0 ≤ (instDst B.insts.val[i]).val → (instDst B.insts.val[i]).val < info.nt.val)) ∧
    AvailTerm (CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length) B.term ∧
    ∀ s ∈ termSuccs B.term, 0 < s.val ∧ s.val < f.blocks.val.length ∧
      (∀ z, z < info.nt.val.toNat → AvB av info.nt s.val.toNat z →
        CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length z) ∧
      ∃ S, f.blocks.val[s.val.toNat]? = some S ∧ ∀ P ∈ S.phis.val, ∃ a, phiArg P b = some a ∧
        AvailAtom (CurAt info.nt.val.toNat (AvB av info.nt b) B B.insts.val.length) a

/-- `check_avail` succeeds only on a correct initialisation certificate. -/
theorem check_avail_sound {vg : ValGraph} {f : Func} {info : FnInfo} {av : Pion.Array Bool}
    {vids bm_t bm_s : Pion.Array Std.I32} (h : check_avail vg f info av vids bm_t bm_s = ok 0#i32)
    (hinfo : InfoOK f info) : AvailOK vg f info av vids.val bm_t.val bm_s.val := by
  have hnb := hinfo.nb
  have hlenle : f.blocks.val.length ≤ 2147483647 := by have := i32_val_le info.nb; omega
  unfold check_avail at h
  obtain ⟨ta, hta, h⟩ := bind_eq_ok h
  obtain ⟨t2, ht2, h⟩ := bind_eq_ok h
  split at h
  · exact absurd (ok_inj' h) (by decide)
  rename_i h2f
  have hvl : vids.val.length = info.nt.val.toNat ∧ 0 ≤ info.nt.val := by
    split at ht2
    · cases ok_inj' ht2; exact absurd rfl h2f
    · obtain ⟨tl, htl, ht2⟩ := bind_eq_ok ht2
      obtain ⟨htl1, -⟩ := arr_length_ok htl
      cases ok_inj' ht2
      simp only [bne_iff_ne, ne_eq, Decidable.not_not] at h2f
      have : tl.val = info.nt.val := by rw [h2f]
      exact ⟨by omega, by omega⟩
  obtain ⟨s0, hs0, h⟩ := bind_eq_ok h
  have h0 := avail_loop0 _ s0 hs0 rfl
  cases s0 with
  | inl e => simp only at h; exact absurd (ok_inj' h) h0
  | inr t1 =>
  simp only at h
  obtain ⟨s1, hs1, h⟩ := bind_eq_ok h
  -- the scan over the blocks
  unfold check_avail_loop1 at hs1
  have key := scan_loop (fun b => check_avail_loop1.body info.nb info bm_t bm_s vg info.nt av vids f b)
    f.blocks.val.length
    (fun k => info.reach.val[k]? = some true → AvailBlock vg f info av vids.val bm_t.val bm_s.val k)
    (fun _ e => e ≠ 0#i32) (fun _ => True)
    (by
      intro bI c hb0 hc
      unfold check_avail_loop1.body at hc
      split at hc
      · rename_i hlt
        have hlt' : bI.val < f.blocks.val.length := by simpa [i32_lt_iff, hnb] using hlt
        have hb1 : bI.val < 2147483647 := by omega
        left
        refine ⟨hlt', hlenle, ?_⟩
        obtain ⟨t4, ht4, hc⟩ := bind_eq_ok hc
        obtain ⟨_, ht4l, ht4v⟩ := arr_get_ok ht4
        obtain ⟨sres, hsres, hc⟩ := bind_eq_ok hc
        have hbI : bI = i32n bI.val.toNat := i32n_of_val hb0
        -- the block's analysis
        have hblk : (∀ e, sres = .inl e → e ≠ 0#i32) ∧ (t4 = true → sres = .inr () →
            AvailBlock vg f info av vids.val bm_t.val bm_s.val bI.val.toNat) := by
          split at hsres
          · rename_i h4
            try simp only at hsres
            obtain ⟨q2, hq2, hsres⟩ := bind_eq_ok hsres
            obtain ⟨j1, xs1⟩ := q2
            try simp only [uncurry_apply_pair] at hsres
            have hxs := avail_loop2 (0#i32, _) _ hq2 rfl
            dsimp only at hxs
            obtain ⟨s3, hs3, hsres⟩ := bind_eq_ok hsres
            have h3 := avail_loop3 hb0 hb1 _ s3 hs3 rfl
            cases s3 with
            | inl e =>
              simp only at hsres
              cases ok_inj' hsres
              exact ⟨fun e' he => (by cases he; exact h3), fun _ he => (by cases he)⟩
            | inr x1 =>
            simp only at hsres
            obtain ⟨q5, hq5, hsres⟩ := bind_eq_ok hsres
            obtain ⟨y1, cur1⟩ := q5
            try simp only [uncurry_apply_pair] at hsres
            have h5 := avail_loop5 (0#i32, Pion.Array.make info.nt false) _ hq5
              ⟨by simp, fun y hy => by
                simp only [Pion.Array.make, listMake, List.getElem?_replicate] at hy
                split at hy <;> cases hy⟩
            dsimp only at h5
            obtain ⟨B, hB, hsres⟩ := bind_eq_ok hsres
            obtain ⟨_, hBl, hBv⟩ := arr_get_ok hB
            have hBb : f.blocks.val[bI.val.toNat]? = some B := by rw [List.getElem?_eq_getElem hBl, hBv]
            obtain ⟨q6, hq6, hsres⟩ := bind_eq_ok hsres
            obtain ⟨i1, cur2⟩ := q6
            try simp only [uncurry_apply_pair] at hsres
            have h6 := avail_loop6 (fun t => AvB av info.nt bI.val.toNat t) (0#i32, cur1) _ hq6
              ⟨by simp, fun t ht => Or.inl (by
                have := h5.2 t ht
                unfold AvB; rw [← hbI]; exact this)⟩
            dsimp only at h6
            obtain ⟨B2, hB2, hsres⟩ := bind_eq_ok hsres
            rw [hB] at hB2; cases ok_inj' hB2
            obtain ⟨s7, hs7, hsres⟩ := bind_eq_ok hsres
            have hcl1 : cur1.val.length = info.nt.val.toNat := by
              rw [h5.1]; simp [Pion.Array.make, listMake]
            have h7 := avail_loop7 hb0 hb1 (fun t => AvB av info.nt bI.val.toNat t ∨ ∃ P ∈ B.phis.val, P.dst.val = t)
              info.nt.val.toNat (0#i32, cur2) s7 hs7 rfl (by rw [h6.1, hcl1]) h6.2.1
            cases s7 with
            | inl e =>
              simp only at hsres
              cases ok_inj' hsres
              exact ⟨fun e' he => (by cases he; exact h7), fun _ he => (by cases he)⟩
            | inr q7 =>
            obtain ⟨i21, cur3⟩ := q7
            simp only at hsres h7
            obtain ⟨h7i, h7c⟩ := h7
            obtain ⟨B3, hB3, hsres⟩ := bind_eq_ok hsres
            rw [hB] at hB3; cases ok_inj' hB3
            obtain ⟨t35, ht35, hsres⟩ := bind_eq_ok hsres
            split at hsres
            · cases ok_inj' hsres
              exact ⟨fun e' he => (by cases he; exact b1_ne0 hb0 hb1), fun _ he => (by cases he)⟩
            rename_i h35
            have h35t : t35 = true := by revert h35; cases t35 <;> decide
            rw [h35t] at ht35
            simp only [term_nsucc_spec, bind_ok] at hsres
            obtain ⟨s8, hs8, hsres⟩ := bind_eq_ok hsres
            have h8 := avail_loop8 (nsucc_val B.term) hnb hb0 hb1 _ s8 hs8 rfl
            -- from the arrays to `CurAt`
            have hcur3 : ∀ t : Nat, cur3.val[t]? = some true →
                CurAt info.nt.val.toNat (AvB av info.nt bI.val.toNat) B B.insts.val.length t := by
              intro t ht
              obtain ⟨hlt, hor⟩ := h7c t ht
              refine ⟨hlt, ?_⟩
              rcases hor with (h1 | h1) | h1
              · exact Or.inl h1
              · exact Or.inr (Or.inl h1)
              · exact Or.inr (Or.inr h1)
            cases s8 with
            | inl e =>
              simp only at hsres
              cases ok_inj' hsres
              exact ⟨fun e' he => (by cases he; exact h8), fun _ he => (by cases he)⟩
            | inr k1 =>
            simp only at hsres
            cases ok_inj' hsres
            refine ⟨fun e' he => (by cases he), fun _ _ => ⟨?_, fun B' hB' => ?_⟩⟩
            · intro j sb hj hsb x hx hav v hv hv0
              rw [← hbI] at hj
              exact h3 sb (hxs j sb hj hsb) x hx (by unfold AvB at hav; rw [← hbI] at hav; exact hav) v hv hv0
            · rw [hBb] at hB'
              cases hB'
              refine ⟨fun P hP => ?_, fun i hi => ?_, ?_, fun sk hsk => ?_⟩
              · obtain ⟨k, hkl, rfl⟩ := List.getElem_of_mem hP
                have := h6.2.2 k (by simp) hkl
                rw [hcl1] at this
                exact ⟨this.1, by omega⟩
              · obtain ⟨hi1, hi2⟩ := h7i i hi
                refine ⟨availInst_mono (fun t ht => ⟨ht.1, ?_⟩) hi1, fun h' => by have := hi2 h'; omega⟩
                rcases ht.2 with (h1 | h1) | h1
                · exact Or.inl h1
                · exact Or.inr (Or.inl h1)
                · exact Or.inr (Or.inr h1)
              · exact availTerm_mono hcur3 (avail_term_ops_true ht35)
              · obtain ⟨hs0, hs1, h9, S, hS, h10⟩ := h8 sk hsk
                refine ⟨hs0, hs1, fun z hz hav => hcur3 z (h9 z hz (by
                    unfold AvB at hav; rw [← i32n_of_val (by omega : 0 ≤ sk.val)] at hav; exact hav)),
                  S, hS, fun P hP => ?_⟩
                obtain ⟨a, ha, hav⟩ := h10 P hP
                exact ⟨a, ha, availAtom_mono hcur3 hav⟩
          · cases ok_inj' hsres
            exact ⟨fun e he => (by cases he), fun h' => absurd h' ‹_›⟩
        cases sres with
        | inl e => simp only at hc; left; exact ⟨_, (ok_inj' hc).symm, hblk.1 e rfl⟩
        | inr u =>
          simp only at hc
          right
          refine ⟨fun hr => hblk.2 ?_ rfl, (ok_inj' hc).symm⟩
          rw [List.getElem?_eq_getElem ht4l, ht4v] at hr
          exact Option.some.inj hr
      · rename_i hge
        right
        exact ⟨by simpa [i32_lt_iff, hnb] using hge, _, (ok_inj' hc).symm, trivial⟩)
  have hk := key 0#i32 s1 hs1 (by simp)
  cases s1 with
  | inl e => simp only at h; obtain ⟨_, _, _, he, _⟩ := hk; exact absurd (ok_inj' h) he
  | inr b1 =>
  have hall : ∀ b, b < f.blocks.val.length → info.reach.val[b]? = some true →
      AvailBlock vg f info av vids.val bm_t.val bm_s.val b := fun b hb hr => hk.2 b (by simp) hb hr
  refine ⟨hvl.1, hvl.2, fun t ht hav => ?_, fun b hr hb j sb hj hsb => (hall b hb hr).1 j sb hj hsb,
    fun b B hr hB => ?_⟩
  · unfold AvB at hav
    rw [i32_mul0_add, h0 t ht] at hav
    cases ok_inj' hav
  · have hb : b < f.blocks.val.length := by
      by_contra hc; rw [List.getElem?_eq_none (by omega)] at hB; cases hB
    exact (hall b hb hr).2 B hB

end PionProofs.QbeTvP
