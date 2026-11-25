/-
Invariants behind three byte-identical compile-speed optimizations:
  1. `compiler/src/core/inline_rc.pion` `irc_may_define_safe` and
     `irc_line_has_phi` (`Select`): the two-byte opcode prefilter accepts every
     opcode that can extend the safe-address tables (`hits`), so skipping the
     rest leaves them unchanged (`safeStep`), and a line the parser takes for a
     `phi` contains the bytes `phi` (`phi_required`).
  2. `irc_unique_lhs_ends` and its users in `irc_collect_immortal_regs`
     (`Census`): when no two definitions share a bucket, all names are distinct
     (`accepted`) and the definition Map would count one for each (`lookup_one`);
     the canonical load operand starts ten bytes after the name
     (`load_operand`), the slot filter only drops lookups that miss
     (`private_bucket`), nine digits fit an `Int` (`ninth_digit_fits`), and the
     load edge is the same (`load_edge`).
  3. `compiler/src/core/qbe.pion` `qbe_block_needs_data_ptr_scan` (`Demand`):
     it holds exactly for the blocks whose emission reads the data-pointer
     predicate (`need_iff`, `guarded_read`, `emitted`); the leaf arms of
     `qbe_expr_has_any_data_ptr` merge into one (`leaf_default`).

Plain kernel checks, no proof holes (compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeInlineRcSpeedOpts

namespace Select
abbrev Bytes := List Nat
def allowed : List Bytes := [[97,108,108,111,99,52], [97,108,108,111,99,56],
  [97,108,108,111,99,49,54], [97,100,100], [99,111,112,121]]
def acceptsPrefix : Bytes → Bool
  | a :: b :: _ => (a == 97 && (b == 108 || b == 100 || b ≥ 128)) ||
      (a == 99 && (b == 111 || b ≥ 128)) || a ≥ 128
  | _ => false

theorem hits (op : Bytes) (h : op ∈ allowed) : acceptsPrefix op = true := by
  simp [allowed] at h
  rcases h with h | h | h | h | h <;> subst op <;> decide

theorem safeStep {S : Type} (applyOp : Bytes → S → S) (op : Bytes) (old : S)
    (noop : op ∉ allowed → applyOp op old = old) :
    (if acceptsPrefix op then applyOp op old else old) = applyOp op old := by
  cases e : acceptsPrefix op with
  | true => rfl
  | false =>
    have h : op ∉ allowed := fun k => Bool.noConfusion (e.symm.trans (hits op k))
    exact (noop h).symm

-- The raw parser checks these three literal code units within its code range.
def checksPhi (raw : Bytes) (offset : Nat) : Bool :=
  match raw.drop offset with
  | 112 :: 104 :: 105 :: _ => true
  | _ => false

theorem phi_required (raw : Bytes) (offset : Nat) (h : checksPhi raw offset = true) :
    List.IsInfix [112,104,105] raw := by
  unfold checksPhi at h
  split at h
  next tail he =>
    refine ⟨raw.take offset, tail, ?_⟩
    have e := List.take_append_drop offset raw
    rw [he] at e
    simpa [List.append_assoc] using e
  next => contradiction
end Select

namespace Census
-- Each accepted definition has one ASCII spelling. A repeated spelling
-- must select the same bucket even when distinct spellings collide.
def scan (bucket : String → Nat) (seen : List Nat) : List String → Bool
  | [] => true
  | n :: ns => !(seen.contains (bucket n)) && scan bucket (bucket n :: seen) ns

theorem accepted (b : String → Nat) (ks : List String) (ss : List Nat)
    (h : scan b ss ks = true) :
    ks.Nodup ∧ ∀ k ∈ ks, b k ∉ ss := by
  induction ks generalizing ss with
  | nil => simp
  | cons k rest ih =>
    simp [scan] at h
    obtain ⟨nd, fresh⟩ := ih (b k :: ss) h.2
    constructor
    · apply List.nodup_cons.mpr
      refine ⟨?_, nd⟩
      intro hk
      exact fresh k hk (by simp)
    · intro x hx
      rcases List.mem_cons.mp hx with e | hr
      · simpa [e] using h.1
      · intro hs
        exact fresh x hr (List.mem_cons_of_mem _ hs)

private theorem one_of_mem {ks : List String} {x : String}
    (nd : ks.Nodup) (hx : x ∈ ks) : ks.count x = 1 := by
  induction ks with
  | nil => simp at hx
  | cons a xs ih =>
    obtain ⟨ha, ht⟩ := List.nodup_cons.mp nd
    by_cases e : a = x
    · subst a; simp [List.count_eq_zero.mpr ha]
    · have hm : x ∈ xs := (List.mem_cons.mp hx).resolve_left (Ne.symm e)
      simp [e, ih ht hm]

theorem lookup_one (b : String → Nat) (ks params : List String)
    (ok : scan b [] ks = true) (x : String) (hx : x ∈ ks) (hp : x ∉ params) :
    (params ++ ks).count x = 1 := by
  have nd := (accepted b ks [] ok).1
  simp [List.count_append, List.count_eq_zero.mpr hp, one_of_mem nd hx]

-- In the certified load spelling the original trimmed operand starts
-- exactly ten bytes after the definition name. The following percent sign
-- and identifier bytes need no scalar decoding.
theorem load_operand (lhs ident : List Nat) :
    (lhs ++ [32,61,108,32,108,111,97,100,108,32,37] ++ ident).drop
      (lhs.length + 10) = 37 :: ident := by simp [List.append_assoc]

theorem private_bucket {K S : Type} (bucket : K → Nat) (bits : Nat → Bool)
    (slots : K → Bool) (covered : ∀ x, slots x = true → bits (bucket x) = true)
    (k : K) (act old : S) :
    (if bits (bucket k) then (if slots k then act else old) else old) =
      (if slots k then act else old) := by
  cases e : slots k <;> simp_all

-- The largest prefix before the ninth multiplication has eight digits.
theorem ninth_digit_fits (id digit : Nat) (hi : id ≤ 99999999) (hd : digit ≤ 9) :
    id * 10 + digit < 2147483648 := by omega

-- Reads of latest stores and entry initialization feed exactly one edge.
def loadSource (addr : String) (latest : Option String) (inEntry : Bool) :=
  match latest with
  | some v => some v
  | none => if inEntry then some ("=" ++ addr) else none

theorem load_edge (addr : String) (latest : Option String) (init ok flagged : Bool)
    (h : ok = true → flagged = true) :
    (if flagged && ok then loadSource addr latest init else none) =
      (if ok then loadSource addr latest init else none) := by
  cases ok <;> simp_all

end Census

namespace Demand
inductive Row where | bind | guard | other deriving DecidableEq
def need : List Row → Bool
  | [] => false
  | r :: rs => r == .guard || (r == .bind && !rs.isEmpty) || need rs

def reads : List Row → Prop
  | [] => False
  | r :: rs => r = .guard ∨ (r = .bind ∧ rs ≠ []) ∨ reads rs

theorem need_iff (xs : List Row) : need xs = true ↔ reads xs := by
  induction xs with
  | nil => simp [need,reads]
  | cons x xs ih => cases x <;> cases xs <;> simp_all [need,reads]

theorem guarded_read (xs : List Row) (dp : Bool) (observed : reads xs) :
    (need xs && dp) = dp := by simp [(need_iff xs).2 observed]

-- Leaf constructors all return the same value; only recursive cases matter.
theorem leaf_default (leaf : Bool) (visit : Bool) :
    (if leaf then false else visit) = (if !leaf then visit else false) := by
  cases leaf <;> rfl
theorem emitted {Out : Type} (xs : List Row) (dp : Bool) (emit : Bool → Out)
    (dead : ¬ reads xs → emit false = emit true) :
    emit (need xs && dp) = emit dp := by
  by_cases h : reads xs
  · rw [guarded_read xs dp h]
  · have hn : need xs = false := by
      cases he : need xs <;> simp_all [need_iff]
    cases dp <;> simp [hn, dead h]

end Demand

end PionQbeInlineRcSpeedOpts
