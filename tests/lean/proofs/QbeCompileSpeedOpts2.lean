/-
Invariants behind four byte-identical compile-speed optimizations and one
undefined-behavior fix:
  1. `vendor/qbe/amd64/isel.c` `AddrNums`: recording each touched key once and
     zeroing only the recorded keys restores the all-zero table
     (`record_nodup`, `write_support`, `clear_keys`, `sparse_reset`).
  2. `vendor/qbe/live.c` `filllive`: when `out` is unchanged, repeating the
     block transfer adds nothing to `in`, pressure or `gen` (`stable_block`).
  3. `compiler/src/core/inline_rc.pion` `irc_has_candidate_pair`: an increment
     followed by a decrement of the same temporary is always found
     (`dec_witness`, `pair_witness`).
  4. `vendor/qbe/copy.c` `copyref`: for every nonnegative int64 the unsigned
     mask test equals the mathematical one, the maximum included
     (`unsigned_mask`).
  5. `vendor/qbe/parse.c` `nextbyte`: two reads with the same transition give
     the lexer the same trace (`read_trace`).

No imports and no proof holes; plain kernel checks (compatible with
both standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeCompileSpeedOpts2

def put (table : Nat → α) (key : Nat) (v : α) : Nat → α :=
  fun k => if k = key then v else table k

def record (keys : List Nat) (k : Nat) : List Nat :=
  if k ∈ keys then keys else k :: keys

theorem record_nodup (keys : List Nat) (k : Nat) (h : keys.Nodup) :
    (record keys k).Nodup := by
  by_cases hk : k ∈ keys <;> simp [record, hk, h]

theorem write_support (zero : α) (table : Nat → α) (keys : List Nat)
    (k : Nat) (v : α) (h : ∀ j, j ∉ keys → table j = zero) :
    ∀ j, j ∉ record keys k → put table k v j = zero := by
  intro j hj
  by_cases hk : k ∈ keys
  · simp [record, hk] at hj
    have hjk : j ≠ k := by rintro rfl; exact hj hk
    simp [put, hjk, h j hj]
  · simp [record, hk] at hj
    simp [put, hj.1, h j hj.2]

theorem clear_keys (zero : α) (keys : List Nat) (table : Nat → α) (j : Nat) :
    (keys.foldl (fun t k => put t k zero) table) j =
    (if j ∈ keys then zero else table j) := by
  induction keys generalizing table with
  | nil => simp
  | cons k ks ih =>
    simp only [List.foldl_cons, ih, List.mem_cons, put]
    by_cases hj : j ∈ ks <;> simp [hj]

theorem sparse_reset (zero : α) (keys : List Nat) (table : Nat → α)
    (support : ∀ j, j ∉ keys → table j = zero) :
    keys.foldl (fun t k => put t k zero) table = fun _ => zero := by
  funext j
  rw [clear_keys]
  split <;> simp_all

-- Phi edge uses are always accumulated. The local transfer computes in and
-- pressure from out and unions its fixed instruction operands into gen.
def transfer (analyze : α → β × γ) (localUses : Nat → Prop)
    (out : α) (gen : Nat → Prop) := (analyze out, fun k => gen k ∨ localUses k)

theorem stable_block (analyze : α → β × γ) (localUses edge gen : Nat → Prop)
    (previous current : α) (same : current = previous) :
    transfer analyze localUses current (fun k => (gen k ∨ localUses k) ∨ edge k) =
    (analyze previous, fun k => (gen k ∨ localUses k) ∨ edge k) := by
  cases same
  unfold transfer
  congr 1
  funext k
  apply propext
  constructor
  · rintro (h | h)
    · exact h
    · exact Or.inl (Or.inr h)
  · exact Or.inl

inductive RC | inc (k : Nat) | dec (k : Nat) | other
  deriving DecidableEq

def possible (seen : List Nat) : List RC → Bool
  | [] => false
  | .inc k :: rest => possible (k :: seen) rest
  | .dec k :: rest => seen.contains k || possible seen rest
  | .other :: rest => possible seen rest

theorem dec_witness (pre post : List RC) (seen : List Nat) (k : Nat) (h : k ∈ seen) :
    possible seen (pre ++ RC.dec k :: post) = true := by
  induction pre generalizing seen with
  | nil => simp [possible, h]
  | cons a ps ih =>
    cases a with
    | inc n => simpa [possible] using ih (n :: seen) (by simp [h])
    | dec n => simp [possible, ih seen h]
    | other => simp [possible, ih seen h]

theorem pair_witness (pre mid post : List RC) (k : Nat) (seen : List Nat) :
    possible seen (pre ++ RC.inc k :: (mid ++ RC.dec k :: post)) = true := by
  induction pre generalizing seen with
  | nil => simp [possible, dec_witness mid post (k :: seen) k (by simp)]
  | cons a ps ih =>
    cases a <;> simp [possible, ih]

theorem unsigned_mask (v : Nat) (h : v < 2^63) :
    (((v+1) % 2^64) &&& (v % 2^64)) = ((v+1) &&& v) := by
  have h₁ : v+1 < 2^64 := by omega
  have h₂ : v < 2^64 := by omega
  rw [Nat.mod_eq_of_lt h₁, Nat.mod_eq_of_lt h₂]

-- The C library defines both reads by the same byte-or-EOF transition when a
-- stream has one owner. Lifting that transition through arbitrary lexer steps
-- preserves the entire token/result trace for any finite run.
theorem read_trace (regular unlocked : σ → α × σ)
    (singleOwner : ∀ s, regular s = unlocked s)
    (lexer : (σ → α × σ) → σ → β) (s : σ) :
    lexer regular s = lexer unlocked s := by
  rw [funext singleOwner]

end PionQbeCompileSpeedOpts2
