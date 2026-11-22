/-
Proofs over the extracted capability table (`tests/lean/captable`): the
`count` invariant, frame lemmas, monotonicity of `mint` and completeness of
`revoke_badge`.
-/
import Captable.Funs
import PionProofs.Common
open Aeneas Aeneas.Std Result Pion WP

set_option maxRecDepth 10000

namespace PionProofs.CapTableP

open PionProofs captable

def isNull : Cap → Bool
  | .Null => true
  | _ => false

def hasBadge (c : Cap) (b : Std.U64) : Bool :=
  match c with
  | .Endpoint x _ _ => x == b
  | _ => false

/-- Number of occupied slots. -/
def countNonNull (l : List Cap) : Nat := l.countP (fun c => !isNull c)

/-- The global invariant: `count` is the number of non-`Null` slots. -/
def CapTableInv (t : CapTable) : Prop :=
  t.slots.val.length ≤ 2147483647 ∧ t.count.val = countNonNull t.slots.val

/-- `t'` is `t` with slot `k` overwritten by `c`. -/
def Applied (t t' : CapTable) (k : Nat) (c : Cap) : Prop :=
  k < t.slots.val.length ∧ t'.slots.val = t.slots.val.set k c

theorem cap_is_null_eq (c : Cap) : cap_is_null c = ok (isNull c) := by
  cases c <;> rfl

theorem cap_has_badge_eq (c : Cap) (b : Std.U64) : cap_has_badge c b = ok (hasBadge c b) := by
  cases c <;> rfl

theorem hasBadge_not_null {c : Cap} {b : Std.U64} (h : hasBadge c b = true) : isNull c = false := by
  cases c <;> simp_all [hasBadge, isNull]

theorem count_le (l : List Cap) : countNonNull l ≤ l.length := List.countP_le_length

theorem count_set (l : List Cap) (k : Nat) (c : Cap) (hk : k < l.length) :
    countNonNull (l.set k c) + (if isNull l[k] = false then 1 else 0) =
      countNonNull l + (if isNull c = false then 1 else 0) := by
  unfold countNonNull
  rw [List.countP_set hk]
  have hle : (if (!isNull l[k]) = true then 1 else 0) ≤ l.countP (fun c => !isNull c) := by
    split
    · exact List.countP_pos_iff.2 ⟨l[k], List.getElem_mem hk, by assumption⟩
    · omega
  cases h1 : isNull l[k] <;> cases h2 : isNull c <;> simp_all

theorem inv_add (t : CapTable) (k : Nat) (c : Cap) (hI : CapTableInv t) (hk : k < t.slots.val.length)
    (hold : isNull t.slots.val[k] = true) (hc : isNull c = false) :
    CapTableInv ⟨⟨t.slots.val.set k c⟩, Pion.I32.add t.count 1#i32⟩ := by
  obtain ⟨hlen, hcnt⟩ := hI
  have hs := count_set t.slots.val k c hk
  simp only [hold, hc, Bool.true_eq_false, ↓reduceIte] at hs
  have hb := count_le (t.slots.val.set k c)
  simp only [List.length_set] at hb
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  have ha := i32_add_val t.count 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
  refine ⟨by simpa using hlen, ?_⟩
  show (Pion.I32.add t.count 1#i32).val = countNonNull (t.slots.val.set k c)
  rw [ha, h1v]
  omega

theorem inv_sub (t : CapTable) (k : Nat) (hI : CapTableInv t) (hk : k < t.slots.val.length)
    (hold : isNull t.slots.val[k] = false) :
    CapTableInv ⟨⟨t.slots.val.set k .Null⟩, Pion.I32.sub t.count 1#i32⟩ ∧
      countNonNull (t.slots.val.set k .Null) + 1 = countNonNull t.slots.val := by
  obtain ⟨hlen, hcnt⟩ := hI
  have hs := count_set t.slots.val k .Null hk
  have hnn : isNull Cap.Null = true := rfl
  simp only [hold, hnn, Bool.true_eq_false, ↓reduceIte] at hs
  have hb := count_le t.slots.val
  have h1v : (1#i32 : Std.I32).val = 1 := by simp
  have ha := i32_sub_val t.count 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
  refine ⟨⟨by simpa using hlen, ?_⟩, by omega⟩
  show (Pion.I32.sub t.count 1#i32).val = countNonNull (t.slots.val.set k .Null)
  rw [ha, h1v]
  omega

theorem guard1 {α : Type} (a : Pion.Array α) (s : Std.I32) (h : a.val.length ≤ 2147483647) :
    (do
      if s >= 0#i32 then
        let n ← Pion.Array.length a
        ok (decide (s < n))
      else ok false : Result Bool) = ok (decide (0 ≤ s.val ∧ s.val < a.val.length)) := by
  obtain ⟨n, hn, he⟩ := arr_len_eq a h
  have h0v : (0#i32 : Std.I32).val = 0 := by simp
  by_cases h0 : 0 ≤ s.val
  · have h0' : s >= 0#i32 := by
      show (0#i32 : Std.I32).val ≤ s.val
      omega
    rw [ite_eq_left h0', he, b_ok]
    congr 1
    exact decide_eq_decide.2 ⟨fun hl => ⟨h0, by have : s.val < n.val := hl; omega⟩,
      fun hl => by show s.val < n.val; omega⟩
  · have h0' : ¬ s >= 0#i32 := by
      intro e
      have e' : (0#i32 : Std.I32).val ≤ s.val := e
      omega
    rw [ite_eq_right h0']
    congr 1
    symm
    exact decide_eq_false (fun hc => h0 hc.1)

theorem guard2 {α : Type} (a : Pion.Array α) (b : Bool) (d : Std.I32)
    (h : a.val.length ≤ 2147483647) :
    (do
      if (b && decide (d >= 0#i32)) then
        let n ← Pion.Array.length a
        ok (decide (d < n))
      else ok false : Result Bool) = ok (b && decide (0 ≤ d.val ∧ d.val < a.val.length)) := by
  cases b
  · simp
  · simp only [Bool.true_and, decide_eq_true_eq]
    exact guard1 a d h

macro "bs" : tactic =>
  `(tactic| simp only [b_ok, cap_is_null_eq, Bool.not_true, Bool.not_false, Bool.false_eq_true,
      ↓reduceIte])

/-- Result of a table operation: the invariant holds, success establishes `A`,
and failure leaves the table untouched. -/
def OpPost (t t' : CapTable) (res : Pion.Res Unit Std.I32) (A : Prop) : Prop :=
  CapTableInv t' ∧ (res = .Ok () → A) ∧ (res ≠ .Ok () → t' = t)

theorem err_post {t : CapTable} {A : Prop} (hI : CapTableInv t) (e : Std.I32) :
    OpPost t t (.Err e) A :=
  ⟨hI, fun h => (by cases h), fun _ => rfl⟩

theorem ok_post {t t' : CapTable} {A : Prop} (hI : CapTableInv t') (hA : A) :
    OpPost t t' (.Ok ()) A :=
  ⟨hI, fun _ => hA, fun h => absurd rfl h⟩

theorem Applied.frame {t t' : CapTable} {k : Nat} {c : Cap} (h : Applied t t' k c) (q : Nat)
    (hq : q ≠ k) : t'.slots.val[q]? = t.slots.val[q]? := by
  rw [h.2]
  exact List.getElem?_set_ne (Ne.symm hq)

theorem insert_master (t : CapTable) (slot : Std.I32) (c : Cap) (hI : CapTableInv t) :
    CapTable.insert t slot c ⦃ r => OpPost t r.2 r.1 (Applied t r.2 slot.val.toNat c) ⦄ := by
  have hlen := hI.1
  unfold CapTable.insert
  rw [guard1 t.slots slot hlen]
  simp only [b_ok]
  by_cases hg : 0 ≤ slot.val ∧ slot.val < t.slots.val.length
  · rw [decide_eq_true hg]
    bs
    obtain ⟨g0, g1⟩ := hg
    have hk : slot.val.toNat < t.slots.val.length := by omega
    rw [arr_get_eq _ _ g0 g1]
    bs
    cases hn : isNull t.slots.val[slot.val.toNat]
    · bs
      rw [spec_ok]
      exact err_post hI _
    · bs
      cases hc : isNull c
      · bs
        rw [arr_set_eq _ _ _ g0 g1]
        simp only [b_ok, spec_ok]
        exact ok_post (inv_add t _ c hI hk hn hc) ⟨hk, rfl⟩
      · bs
        rw [spec_ok]
        exact err_post hI _
  · rw [decide_eq_false hg]
    bs
    rw [spec_ok]
    exact err_post hI _

theorem copy_master (t : CapTable) (src dst : Std.I32) (hI : CapTableInv t) :
    CapTable.copy_cap t src dst ⦃ r => OpPost t r.2 r.1
      (∃ c, t.slots.val[src.val.toNat]? = some c ∧ isNull c = false ∧
        Applied t r.2 dst.val.toNat c) ⦄ := by
  have hlen := hI.1
  unfold CapTable.copy_cap
  rw [guard1 t.slots src hlen]
  simp only [b_ok]
  rw [guard2 t.slots _ dst hlen]
  simp only [b_ok]
  have hgv : (decide (0 ≤ src.val ∧ src.val < t.slots.val.length) &&
      decide (0 ≤ dst.val ∧ dst.val < t.slots.val.length)) =
      decide ((0 ≤ src.val ∧ src.val < t.slots.val.length) ∧
        (0 ≤ dst.val ∧ dst.val < t.slots.val.length)) := (Bool.decide_and _ _).symm
  rw [hgv]
  by_cases hg : (0 ≤ src.val ∧ src.val < t.slots.val.length) ∧
      (0 ≤ dst.val ∧ dst.val < t.slots.val.length)
  · rw [decide_eq_true hg]
    bs
    obtain ⟨⟨s0, s1⟩, d0, d1⟩ := hg
    have hs : src.val.toNat < t.slots.val.length := by omega
    have hd : dst.val.toNat < t.slots.val.length := by omega
    rw [arr_get_eq _ src s0 s1]
    bs
    cases hc : isNull t.slots.val[src.val.toNat]
    · bs
      rw [arr_get_eq _ dst d0 d1]
      bs
      cases hn : isNull t.slots.val[dst.val.toNat]
      · bs
        rw [spec_ok]
        exact err_post hI _
      · bs
        rw [arr_set_eq _ _ _ d0 d1]
        simp only [b_ok, spec_ok]
        exact ok_post (inv_add t _ _ hI hd hn hc)
          ⟨_, List.getElem?_eq_getElem hs, hc, hd, rfl⟩
    · bs
      rw [spec_ok]
      exact err_post hI _
  · rw [decide_eq_false hg]
    bs
    rw [spec_ok]
    exact err_post hI _

/-- What a successful `mint` did: `dst` is an endpoint derived from the one at `src`. -/
def MintA (t t' : CapTable) (src dst : Std.I32) (nb : Std.U64) (aS aR : Bool) : Prop :=
  ∃ ob os or, t.slots.val[src.val.toNat]? = some (.Endpoint ob os or) ∧
    Applied t t' dst.val.toNat (.Endpoint nb (os && aS) (or && aR))

theorem mint_master (t : CapTable) (src dst : Std.I32) (nb : Std.U64) (aS aR : Bool)
    (hI : CapTableInv t) :
    CapTable.mint t src dst nb aS aR ⦃ r => OpPost t r.2 r.1 (MintA t r.2 src dst nb aS aR) ⦄ := by
  have hlen := hI.1
  unfold CapTable.mint
  rw [guard1 t.slots src hlen]
  simp only [b_ok]
  rw [guard2 t.slots _ dst hlen]
  simp only [b_ok]
  have hgv : (decide (0 ≤ src.val ∧ src.val < t.slots.val.length) &&
      decide (0 ≤ dst.val ∧ dst.val < t.slots.val.length)) =
      decide ((0 ≤ src.val ∧ src.val < t.slots.val.length) ∧
        (0 ≤ dst.val ∧ dst.val < t.slots.val.length)) := (Bool.decide_and _ _).symm
  rw [hgv]
  by_cases hg : (0 ≤ src.val ∧ src.val < t.slots.val.length) ∧
      (0 ≤ dst.val ∧ dst.val < t.slots.val.length)
  · rw [decide_eq_true hg]
    bs
    obtain ⟨⟨s0, s1⟩, d0, d1⟩ := hg
    have hs : src.val.toNat < t.slots.val.length := by omega
    have hd : dst.val.toNat < t.slots.val.length := by omega
    rw [arr_get_eq _ dst d0 d1]
    bs
    cases hn : isNull t.slots.val[dst.val.toNat]
    · bs
      rw [spec_ok]
      exact err_post hI _
    · bs
      rw [arr_get_eq _ src s0 s1]
      simp only [b_ok]
      have hget := List.getElem?_eq_getElem hs
      generalize t.slots.val[src.val.toNat] = x at hget ⊢
      cases x with
      | Null =>
        refine (spec_ok _).2 ?_
        exact err_post hI _
      | Mint a b =>
        refine (spec_ok _).2 ?_
        exact err_post hI _
      | Endpoint ob os or =>
        dsimp only
        rw [arr_set_eq _ _ _ d0 d1]
        simp only [b_ok, spec_ok]
        exact ok_post (inv_add t _ _ hI hd hn rfl) ⟨ob, os, or, hget, hd, rfl⟩
  · rw [decide_eq_false hg]
    bs
    rw [spec_ok]
    exact err_post hI _

theorem delete_master (t : CapTable) (slot : Std.I32) (hI : CapTableInv t) :
    CapTable.delete t slot ⦃ r => OpPost t r.2 r.1 (Applied t r.2 slot.val.toNat .Null) ⦄ := by
  have hlen := hI.1
  unfold CapTable.delete
  rw [guard1 t.slots slot hlen]
  simp only [b_ok]
  by_cases hg : 0 ≤ slot.val ∧ slot.val < t.slots.val.length
  · rw [decide_eq_true hg]
    bs
    obtain ⟨g0, g1⟩ := hg
    have hk : slot.val.toNat < t.slots.val.length := by omega
    rw [arr_get_eq _ _ g0 g1]
    bs
    cases hn : isNull t.slots.val[slot.val.toNat]
    · bs
      rw [arr_set_eq _ _ _ g0 g1]
      simp only [b_ok, spec_ok]
      exact ok_post (inv_sub t _ hI hk hn).1 ⟨hk, rfl⟩
    · bs
      rw [spec_ok]
      exact err_post hI _
  · rw [decide_eq_false hg]
    bs
    rw [spec_ok]
    exact err_post hI _

/-! ### `revoke_badge` -/

def RevInv (t : CapTable) (badge : Std.U64) (n : Std.I32)
    (s : Std.I32 × CapTable × Std.I32) : Prop :=
  0 ≤ s.1.val ∧ s.1.val ≤ n.val ∧ n.val = t.slots.val.length ∧
    CapTableInv s.2.1 ∧ s.2.1.slots.val.length = t.slots.val.length ∧
    0 ≤ s.2.2.val ∧ s.2.2.val + countNonNull s.2.1.slots.val = countNonNull t.slots.val ∧
    (∀ (q : Nat) (c : Cap), (q : Int) < s.1.val → s.2.1.slots.val[q]? = some c → hasBadge c badge = false) ∧
    (∀ q : Nat, s.1.val ≤ q → s.2.1.slots.val[q]? = t.slots.val[q]?) ∧
    (∀ (q : Nat) (c : Cap), t.slots.val[q]? = some c → hasBadge c badge = false → s.2.1.slots.val[q]? = some c)

def RevPost (t : CapTable) (badge : Std.U64) (r : Std.I32 × CapTable × Std.I32) : Prop :=
  CapTableInv r.2.1 ∧ r.2.1.slots.val.length = t.slots.val.length ∧
    r.2.2.val + countNonNull r.2.1.slots.val = countNonNull t.slots.val ∧
    (∀ (q : Nat) (c : Cap), r.2.1.slots.val[q]? = some c → hasBadge c badge = false) ∧
    (∀ (q : Nat) (c : Cap), t.slots.val[q]? = some c → hasBadge c badge = false → r.2.1.slots.val[q]? = some c)

theorem rev_body (t : CapTable) (badge : Std.U64) (n : Std.I32)
    (s : Std.I32 × CapTable × Std.I32) (h : RevInv t badge n s) :
    CapTable.revoke_badge_loop0.body n badge s.1 s.2.1 s.2.2 ⦃ r =>
      match r with
      | .done y => RevPost t badge y
      | .cont x' => RevInv t badge n x' ∧ (n.val - x'.1.val).toNat < (n.val - s.1.val).toNat ⦄ := by
  obtain ⟨i, self, rev⟩ := s
  obtain ⟨h0, h1, hn, hI, hl, hr0, hrc, hdone, hrest, hkeep⟩ := h
  dsimp only at h0 h1 hn hI hl hr0 hrc hdone hrest hkeep ⊢
  unfold CapTable.revoke_badge_loop0.body
  by_cases hlt : i < n
  · have hlt' : i.val < n.val := hlt
    rw [ite_eq_left hlt, arr_get_eq _ i h0 (by omega)]
    have hk : i.val.toNat < self.slots.val.length := by omega
    have hmax : self.slots.val.length ≤ 2147483647 := hI.1
    have higet : self.slots.val[i.val.toNat]? = some self.slots.val[i.val.toNat] :=
      List.getElem?_eq_getElem hk
    simp only [b_ok, cap_has_badge_eq]
    have h1v : (1#i32 : Std.I32).val = 1 := by simp
    have hadd := i32_add_val i 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
    rw [h1v] at hadd
    cases hb : hasBadge self.slots.val[i.val.toNat] badge
    · simp only [Bool.false_eq_true, ↓reduceIte, b_ok]
      refine (spec_ok (ControlFlow.cont (Pion.I32.add i 1#i32, self, rev))).2 ?_
      refine ⟨⟨by dsimp only; omega, by dsimp only; omega, hn, hI, hl, hr0, hrc, ?_, ?_, hkeep⟩,
        by dsimp only; omega⟩
      · intro q c hq hc
        dsimp only at hq hc
        by_cases hqi : (q : Int) < i.val
        · exact hdone q c hqi hc
        · have e : q = i.val.toNat := by omega
          subst e
          rw [higet] at hc
          have e := Option.some.inj hc
          subst e
          exact hb
      · intro q hq
        dsimp only at hq
        exact hrest q (by omega)
    · simp only [↓reduceIte]
      rw [arr_set_eq _ i _ h0 (by omega)]
      simp only [b_ok]
      have hnn := hasBadge_not_null hb
      obtain ⟨hI', hc'⟩ := inv_sub self _ hI hk hnn
      have hc1 := count_le t.slots.val
      have hra := i32_add_val rev 1#i32 (by rw [h1v]; omega) (by rw [h1v]; omega)
      rw [h1v] at hra
      refine (spec_ok (ControlFlow.cont (Pion.I32.add i 1#i32,
        (⟨⟨self.slots.val.set i.val.toNat .Null⟩, Pion.I32.sub self.count 1#i32⟩ : CapTable),
        Pion.I32.add rev 1#i32))).2 ?_
      refine ⟨⟨by dsimp only; omega, by dsimp only; omega, hn, hI',
        by dsimp only; simpa using hl, by dsimp only; omega, by dsimp only; omega, ?_, ?_, ?_⟩,
        by dsimp only; omega⟩
      · intro q c hq hc
        dsimp only at hq hc
        by_cases hqi : q = i.val.toNat
        · subst hqi
          rw [List.getElem?_set_self hk] at hc
          have e := Option.some.inj hc
          subst e
          rfl
        · rw [List.getElem?_set_ne (Ne.symm hqi)] at hc
          exact hdone q c (by omega) hc
      · intro q hq
        dsimp only at hq
        rw [List.getElem?_set_ne (by omega)]
        exact hrest q (by omega)
      · intro q c hq hcb
        dsimp only
        by_cases hqi : q = i.val.toNat
        · subst hqi
          have e := hrest _ (show i.val ≤ (i.val.toNat : Int) by omega)
          rw [higet, hq] at e
          have e' := Option.some.inj e
          subst e'
          rw [hb] at hcb
          cases hcb
        · rw [List.getElem?_set_ne (Ne.symm hqi)]
          exact hkeep q c hq hcb
  · have hlt' : ¬ i.val < n.val := hlt
    rw [ite_eq_right hlt, spec_ok]
    refine ⟨hI, hl, hrc, ?_, hkeep⟩
    intro q c hc
    have hq : q < self.slots.val.length := by
      by_contra hcon
      rw [List.getElem?_eq_none (not_lt.1 hcon)] at hc
      cases hc
    exact hdone q c (by omega) hc

theorem rev_loop (t : CapTable) (badge : Std.U64) (n i : Std.I32) (self : CapTable) (rev : Std.I32)
    (h : RevInv t badge n (i, self, rev)) :
    CapTable.revoke_badge_loop0 n badge i self rev ⦃ r => RevPost t badge r ⦄ := by
  unfold CapTable.revoke_badge_loop0
  refine loop.spec_decr_nat (fun s => (n.val - s.1.val).toNat) (RevInv t badge n) _ _ _ ?_ h
  rintro ⟨i', self', rev'⟩ hI
  have hb := rev_body t badge n (i', self', rev') hI
  dsimp only at hb ⊢
  refine spec_mono hb ?_
  rintro (x | y) hr <;> exact hr

theorem revoke_master (t : CapTable) (badge : Std.U64) (hI : CapTableInv t) :
    CapTable.revoke_badge t badge ⦃ r =>
      CapTableInv r.2 ∧ r.2.slots.val.length = t.slots.val.length ∧
      r.1.val + countNonNull r.2.slots.val = countNonNull t.slots.val ∧
      (∀ (q : Nat) (c : Cap), r.2.slots.val[q]? = some c → hasBadge c badge = false) ∧
      (∀ (q : Nat) (c : Cap), t.slots.val[q]? = some c → hasBadge c badge = false → r.2.slots.val[q]? = some c) ⦄ := by
  unfold CapTable.revoke_badge
  refine spec_bind' (Pion.Array.length_spec t.slots hI.1) ?_
  intro n hn
  dsimp only
  have h0v : (0#i32 : Std.I32).val = 0 := by simp
  have hInv : RevInv t badge n (0#i32, t, 0#i32) := by
    unfold RevInv
    dsimp only
    rw [h0v]
    refine ⟨le_refl _, by omega, hn, hI, rfl, le_refl _, by omega, ?_, ?_, ?_⟩
    · intro q c hq
      omega
    · intro q _
      rfl
    · intro q c hc _
      exact hc
  refine spec_bind' (rev_loop t badge n _ t _ hInv) ?_
  rintro ⟨i1, t1, r1⟩ ⟨a, b, c, d, e⟩
  refine (spec_ok (r1, t1)).2 ?_
  exact ⟨a, b, c, d, e⟩

/-! ## Public theorems -/

theorem create_inv (cap : Std.I32) : CapTable.create cap ⦃ t => CapTableInv t ∧ t.count.val = 0 ⦄ := by
  unfold CapTable.create
  simp only [spec_ok]
  have hc : cap.val ≤ 2147483647 := by scalar_tac
  have h0v : (0#i32 : Std.I32).val = 0 := by simp
  refine ⟨⟨?_, ?_⟩, h0v⟩
  · show (listMake cap Cap.Null).length ≤ 2147483647
    simp [listMake]
    omega
  · show (0#i32 : Std.I32).val = countNonNull (listMake cap Cap.Null)
    rw [h0v]
    simp [countNonNull, listMake, List.countP_replicate, isNull]

theorem insert_preserves_inv (t : CapTable) (slot : Std.I32) (c : Cap) (hI : CapTableInv t) :
    CapTable.insert t slot c ⦃ r => CapTableInv r.2 ⦄ :=
  spec_mono (insert_master t slot c hI) fun _ h => h.1

theorem copy_cap_preserves_inv (t : CapTable) (src dst : Std.I32) (hI : CapTableInv t) :
    CapTable.copy_cap t src dst ⦃ r => CapTableInv r.2 ⦄ :=
  spec_mono (copy_master t src dst hI) fun _ h => h.1

theorem mint_preserves_inv (t : CapTable) (src dst : Std.I32) (nb : Std.U64) (aS aR : Bool)
    (hI : CapTableInv t) : CapTable.mint t src dst nb aS aR ⦃ r => CapTableInv r.2 ⦄ :=
  spec_mono (mint_master t src dst nb aS aR hI) fun _ h => h.1

theorem delete_preserves_inv (t : CapTable) (slot : Std.I32) (hI : CapTableInv t) :
    CapTable.delete t slot ⦃ r => CapTableInv r.2 ⦄ :=
  spec_mono (delete_master t slot hI) fun _ h => h.1

theorem revoke_badge_preserves_inv (t : CapTable) (badge : Std.U64) (hI : CapTableInv t) :
    CapTable.revoke_badge t badge ⦃ r => CapTableInv r.2 ⦄ :=
  spec_mono (revoke_master t badge hI) fun _ h => h.1

theorem insert_frame (t : CapTable) (slot : Std.I32) (c : Cap) (hI : CapTableInv t) :
    CapTable.insert t slot c ⦃ r => r.1 = .Ok () →
      ∀ q, q ≠ slot.val.toNat → r.2.slots.val[q]? = t.slots.val[q]? ⦄ :=
  spec_mono (insert_master t slot c hI) fun _ h ho q hq => (h.2.1 ho).frame q hq

theorem copy_cap_frame (t : CapTable) (src dst : Std.I32) (hI : CapTableInv t) :
    CapTable.copy_cap t src dst ⦃ r => r.1 = .Ok () →
      ∀ q, q ≠ dst.val.toNat → r.2.slots.val[q]? = t.slots.val[q]? ⦄ :=
  spec_mono (copy_master t src dst hI) fun _ h ho q hq => by
    obtain ⟨c, _, _, hA⟩ := h.2.1 ho
    exact hA.frame q hq

theorem mint_frame (t : CapTable) (src dst : Std.I32) (nb : Std.U64) (aS aR : Bool)
    (hI : CapTableInv t) :
    CapTable.mint t src dst nb aS aR ⦃ r => r.1 = .Ok () →
      ∀ q, q ≠ dst.val.toNat → r.2.slots.val[q]? = t.slots.val[q]? ⦄ :=
  spec_mono (mint_master t src dst nb aS aR hI) fun _ h ho q hq => by
    obtain ⟨_, _, _, _, hA⟩ := h.2.1 ho
    exact hA.frame q hq

theorem delete_frame (t : CapTable) (slot : Std.I32) (hI : CapTableInv t) :
    CapTable.delete t slot ⦃ r => r.1 = .Ok () →
      ∀ q, q ≠ slot.val.toNat → r.2.slots.val[q]? = t.slots.val[q]? ⦄ :=
  spec_mono (delete_master t slot hI) fun _ h ho q hq => (h.2.1 ho).frame q hq

/-- A minted endpoint never has a right its source lacks. -/
theorem mint_rights_monotone (t : CapTable) (src dst : Std.I32) (nb : Std.U64) (aS aR : Bool)
    (hI : CapTableInv t) :
    CapTable.mint t src dst nb aS aR ⦃ r => r.1 = .Ok () →
      ∃ ob os or ns nr, t.slots.val[src.val.toNat]? = some (.Endpoint ob os or) ∧
        r.2.slots.val[dst.val.toNat]? = some (.Endpoint nb ns nr) ∧
        (ns = true → os = true) ∧ (nr = true → or = true) ⦄ :=
  spec_mono (mint_master t src dst nb aS aR hI) fun _ h ho => by
    obtain ⟨ob, os, or, hs, hk, he⟩ := h.2.1 ho
    refine ⟨ob, os, or, os && aS, or && aR, hs, ?_, ?_, ?_⟩
    · rw [he]
      exact List.getElem?_set_self hk
    · simp only [Bool.and_eq_true]
      exact fun x => x.1
    · simp only [Bool.and_eq_true]
      exact fun x => x.1

/-- After `revoke_badge` no endpoint carries `badge`, every other slot is
unchanged, and the result is the number of capabilities removed. -/
theorem revoke_badge_complete (t : CapTable) (badge : Std.U64) (hI : CapTableInv t) :
    CapTable.revoke_badge t badge ⦃ r =>
      r.2.slots.val.length = t.slots.val.length ∧
      r.1.val + countNonNull r.2.slots.val = countNonNull t.slots.val ∧
      (∀ (q : Nat) (s rcv : Bool), r.2.slots.val[q]? ≠ some (.Endpoint badge s rcv)) ∧
      (∀ (q : Nat) (c : Cap), t.slots.val[q]? = some c → hasBadge c badge = false → r.2.slots.val[q]? = some c) ⦄ :=
  spec_mono (revoke_master t badge hI) fun _ h => by
    obtain ⟨_, hl, hc, hno, hkeep⟩ := h
    refine ⟨hl, hc, ?_, hkeep⟩
    intro q s rcv he
    have := hno q _ he
    simp [hasBadge] at this

end PionProofs.CapTableP
