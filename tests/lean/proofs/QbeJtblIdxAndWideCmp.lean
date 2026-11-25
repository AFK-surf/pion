/-
Arithmetic and state facts behind two QBE code generation changes.

`vendor/qbe/{spill,rega}.c` + `amd64/{emit,elf}.c` (jump-table selectors): a
selector that is dead on every successor may live in the scratch register the
dispatch reserves anyway, and the `movl` that zero-extends the selector is
dropped when a 32-bit write in the block proves the high half is zero.

  1. `keepLive`: overwriting a scratch register that no successor reads
     keeps every live-out register.
  2. `dispatchEq`: the dispatch reaches the same target with the selector in
     the scratch register, for any table (duplicates included) and default.
  3. `normalizeWord`: truncate-then-extend yields the low word.
  4. `provenIndex`, `addressEq`: with a clear high half the normalization is
     the identity and the table address is unchanged.
  5. `spillToIndexedJump`: bounds branch, table load and displacement give
     the same PC from the spilled word as from the (normalized or proven)
     register.

`vendor/qbe/copy.c` `widecmp`: a signed 64-bit comparison of a sign- or
zero-extended word plus a 32-bit offset folds when both ends of the interval
agree.

  6. `uniform`: a relation with equal answers at both ends is constant on
     the interval.
  7. `noWrap`: the sum stays inside the signed 64-bit range.
  8. `enclosure`: adding the offset shifts the interval.
  9. `wordRange`: the interval of a widened 32-bit word.
 10. `machineFold`: the fold is correct for real `BitVec 32` inputs and the
     64-bit machine result.

The models assume the liveness test and the amd64 opcode list of the
implementation; they do not formalize the C code or x86.
-/
import Std

namespace PionQbeJtblIdxAndWideCmp

-- A live-out observation excludes the scratch register. Memory is carried
-- unchanged. The default and repeated table entries are arbitrary values.
def write {R V : Type} [DecidableEq R] (regs : R → V) (r : R) (v : V) : R → V :=
  fun q => if q = r then v else regs q

def target {Label : Type} (word : BitVec 32) (arms : List Label) (fallback : Label) : Label :=
  (arms[word.toNat]?).getD fallback

theorem keepLive {R V : Type} [DecidableEq R] (regs : R → V) (scratch q : R)
    (selector : V) (dead : q ≠ scratch) :
    write regs scratch selector q = regs q := by simp [write, dead]

theorem dispatchEq {R Label : Type} [DecidableEq R] (before : R → BitVec 32)
    (scratch : R) (selector : BitVec 32) (arms : List Label) (fallback : Label) :
    target ((write before scratch selector) scratch) arms fallback =
    target selector arms fallback := by simp [write]

theorem normalizeWord (old : BitVec 64) :
    ((old.setWidth 32).setWidth 64).toNat = (old.setWidth 32).toNat := by
  simp
  exact Nat.lt_trans (Nat.mod_lt _ (by decide : 0 < 4294967296)) (by decide)

-- A dominating unconditional 32-bit write proves this bound on the full
-- physical register. The SIB address is then unchanged if movl is omitted.
theorem provenIndex (old : BitVec 64) (bounded : old.toNat < 2^32) :
    ((old.setWidth 32).setWidth 64) = old := by
  apply BitVec.eq_of_toNat_eq
  rw [normalizeWord]
  simp only [BitVec.toNat_setWidth, Nat.mod_eq_of_lt bounded]

theorem addressEq (old base : BitVec 64) (bounded : old.toNat < 2^32) :
    base + ((old.setWidth 32).setWidth 64) * 4 = base + old * 4 := by
  rw [provenIndex old bounded]

-- Model the emitted unsigned bounds branch and the PIC table's signed
-- displacement. The table memory and default target are arbitrary.
def jump (low : BitVec 32) (index base defaultPC : BitVec 64)
    (entries : Nat) (read32 : BitVec 64 → BitVec 32) : BitVec 64 :=
  if low.toNat < entries then
    base + (read32 (base + index * 4)).signExtend 64
  else
    defaultPC

-- Before the change the low word can be loaded from the private spill
-- home. After it the low word is available in its register. A true flag
-- means the local definition proves that the high half is zero.
theorem spillToIndexedJump (home : BitVec 32) (reg base defaultPC : BitVec 64)
    (entries : Nat) (read32 : BitVec 64 → BitVec 32) (known : Bool)
    (value : reg.setWidth 32 = home)
    (fact : known = true → reg.toNat < 2^32) :
    jump home (home.setWidth 64) base defaultPC entries read32 =
    jump (reg.setWidth 32) (if known then reg else (reg.setWidth 32).setWidth 64)
      base defaultPC entries read32 := by
  subst home
  cases known with
  | false => rfl
  | true => simp only [↓reduceIte, provenIndex reg (fact rfl)]
inductive Rel | ge | gt | le | lt

def holds : Rel → Int → Int → Prop
  | .ge, a, b => a ≥ b
  | .gt, a, b => a > b
  | .le, a, b => a ≤ b
  | .lt, a, b => a < b

theorem uniform (r : Rel) (lo hi x c : Int) (a : lo ≤ x) (b : x ≤ hi)
    (same : holds r lo c ↔ holds r hi c) :
    holds r x c ↔ holds r lo c := by
  cases r with
  | ge => exact ⟨fun h => same.mpr (Int.le_trans h b), fun h => Int.le_trans h a⟩
  | gt => exact ⟨fun h => same.mpr (Int.lt_of_lt_of_le h b), fun h => Int.lt_of_lt_of_le h a⟩
  | le => exact ⟨fun h => Int.le_trans a h, fun h => Int.le_trans b (same.mp h)⟩
  | lt => exact ⟨fun h => Int.lt_of_le_of_lt a h, fun h => Int.lt_of_le_of_lt b (same.mp h)⟩

theorem noWrap (x offset : Int)
    (hx : -2147483648 ≤ x ∧ x ≤ 4294967295)
    (ho : -2147483648 ≤ offset ∧ offset ≤ 2147483647) :
    -(2^63) ≤ x + offset ∧ x + offset < 2^63 := by
  exact ⟨Int.le_trans (by decide : -(2^63 : Int) ≤ -2147483648 + -2147483648)
           (Int.add_le_add hx.1 ho.1),
         Int.lt_of_le_of_lt (Int.add_le_add hx.2 ho.2)
           (by decide : (4294967295 : Int) + 2147483647 < 2^63)⟩

theorem enclosure (lo hi x offset : Int) (a : lo ≤ x) (b : x ≤ hi) :
    lo + offset ≤ x + offset ∧ x + offset ≤ hi + offset :=
  ⟨Int.add_le_add_right a _, Int.add_le_add_right b _⟩

def widened (signed : Bool) (word : BitVec 32) : Int :=
  if signed then word.toInt else Int.ofNat word.toNat

theorem wordRange (signed : Bool) (word : BitVec 32) :
    (if signed then -2147483648 else 0) ≤ widened signed word ∧
    widened signed word ≤ (if signed then 2147483647 else 4294967295) := by
  cases signed with
  | false =>
    have h := word.isLt
    change word.toNat < 4294967296 at h
    change 0 ≤ (↑word.toNat : Int) ∧ (↑word.toNat : Int) ≤ 4294967295
    exact ⟨Int.natCast_nonneg _, Int.ofNat_le.mpr (Nat.le_of_lt_succ h)⟩
  | true =>
    change -2147483648 ≤ word.toInt ∧ word.toInt ≤ 2147483647
    unfold BitVec.toInt
    split
    next positive =>
      have half : word.toNat < 2147483648 := Nat.lt_of_not_ge fun h =>
        Nat.not_lt_of_ge (Nat.mul_le_mul_left 2 h) positive
      exact ⟨Int.le_trans (by decide : (-2147483648 : Int) ≤ 0) (Int.natCast_nonneg _),
             Int.ofNat_le.mpr (Nat.le_of_lt_succ half)⟩
    next negative =>
      have half : 2147483648 ≤ word.toNat := Nat.le_of_not_lt fun h =>
        negative (Nat.mul_lt_mul_of_pos_left h (by decide : 0 < 2))
      have lo : (2147483648 : Int) ≤ ↑word.toNat := Int.ofNat_le.mpr half
      have hi : (↑word.toNat : Int) ≤ 4294967295 :=
        Int.ofNat_le.mpr (Nat.le_of_lt_succ word.isLt)
      exact ⟨Int.sub_le_sub_right lo _, Int.le_trans (Int.sub_le_sub_right hi _)
               (by decide : (4294967295 : Int) - 4294967296 ≤ 2147483647)⟩

theorem machineFold (r : Rel) (signed : Bool) (word : BitVec 32) (offset limit : Int)
    (off : -2147483648 ≤ offset ∧ offset ≤ 2147483647)
    (same : holds r ((if signed then -2147483648 else 0) + offset) limit ↔
      holds r ((if signed then 2147483647 else 4294967295) + offset) limit) :
    holds r (BitVec.ofInt 64 (widened signed word + offset)).toInt limit ↔
    holds r ((if signed then -2147483648 else 0) + offset) limit := by
  obtain ⟨lower, upper⟩ := wordRange signed word
  have global : -2147483648 ≤ widened signed word ∧ widened signed word ≤ 4294967295 := by
    cases signed with
    | false => exact ⟨Int.le_trans (by decide : (-2147483648 : Int) ≤ 0) lower, upper⟩
    | true => exact ⟨lower, Int.le_trans upper (by decide : (2147483647 : Int) ≤ 4294967295)⟩
  obtain ⟨lo, hi⟩ := noWrap _ offset global off
  have exactValue : (BitVec.ofInt 64 (widened signed word + offset)).toInt =
      widened signed word + offset := by
    apply BitVec.toInt_ofInt_eq_self (by decide) <;> first | exact lo | exact hi | exact ⟨lo, hi⟩
  rw [exactValue]
  exact uniform _ _ _ _ _ (Int.add_le_add_right lower _) (Int.add_le_add_right upper _) same

end PionQbeJtblIdxAndWideCmp
