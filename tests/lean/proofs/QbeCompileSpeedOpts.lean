/-
Invariants behind four byte-identical compile-speed optimizations:
  1. `vendor/qbe/ssa.c` `phiins`: visiting only the blocks that define a temp
     (in link order, each block once) leaves the local rewrite and the phi
     worklist unchanged; frontier marks keyed by the temp id never collide.
  2. `vendor/qbe/spill.c`: when both register classes fit, `limit2` keeps
     every live temp, so it and `reloads` can be skipped.
  3. `compiler/src/core/inline_rc.pion` `irc_cancel_same_block_rc`: a block
     with no incoming window and no `pion_rc_inc` cancels nothing and opens
     no window across a trap branch.
  4. `vendor/qbe/util.c` `alloc`: bump slices rounded up to the alignment
     unit never overlap and stay inside the chunk.

No imports and no proof holes; plain kernel checks (compatible with
both standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeCompileSpeedOpts


-- The real local rename state starts empty at each block. Only a definition
-- of t can install a replacement or enqueue a defining block. Supply the real
-- rewrite as the active case, which is identical in both traversals.
structure Instr where
  dst : Option Nat
  args : List Nat

def blockFold (t : Nat) (active : Instr → Option Nat → σ → Option Nat × σ)
    (xs : List Instr) (r : Option Nat) (s : σ) : Option Nat × σ :=
  match xs with
  | [] => (r, s)
  | i :: is =>
    let (r', s') := if r.isSome || i.dst == some t then active i r s else (r, s)
    blockFold t active is r' s'

theorem absent_def_no_rewrite (t : Nat) (active : Instr → Option Nat → σ → Option Nat × σ)
    (xs : List Instr) (s : σ) (h : ∀ i ∈ xs, i.dst ≠ some t) :
    blockFold t active xs none s = (none, s) := by
  induction xs with
  | nil => rfl
  | cons i is ih =>
    have h₁ := h i (by simp)
    have h₂ : ∀ j ∈ is, j.dst ≠ some t := fun j hj => h j (by simp [hj])
    simpa [blockFold, h₁] using ih h₂

-- A stable subsequence preserves the order of all effects, including
-- fresh names, class merges and pushes to the phi worklist.
theorem fold_defining_blocks (keep : β → Bool) (step : σ → β → σ) (blocks : List β)
    (h : ∀ s b, keep b = false → step s b = s) (s : σ) :
    blocks.foldl step s = (blocks.filter keep).foldl step s := by
  induction blocks generalizing s with
  | nil => rfl
  | cons b bs ih =>
    cases hb : keep b <;> simp [hb, h, ih]

-- Within one block all hits share its block id. After the first hit the
-- tail marker equals b, so later occurrences cannot append a second entry.
def recordHits (b : Nat) (hits : List Bool) (already : Bool) (ids : List Nat) : List Nat :=
  match hits with
  | [] => ids
  | h :: hs =>
    recordHits b hs (already || h) (if h && !already then ids ++ [b] else ids)

theorem record_hits_once (b : Nat) (hits : List Bool) (already : Bool) (ids : List Nat) :
    recordHits b hits already ids =
      if !already && hits.contains true then ids ++ [b] else ids := by
  induction hits generalizing already ids with
  | nil => simp [recordHits]
  | cons h hs ih => cases h <;> cases already <;> simp [recordHits, ih]

-- The C array starts zero and the temporary index is positive and strictly
-- increases. Prior epochs cannot look visited in the new epoch.
theorem fresh_mark {old epoch : Nat} (h : old < epoch) : old ≠ epoch := Nat.ne_of_lt h

def limit (k : Nat) (rank : List α → List α) (xs : List α) :=
  if xs.length ≤ k then xs else (rank xs).take k

theorem split_fits (xs : List α) (fp : α → Bool) (rank : List α → List α)
    (kg kf : Nat) (hg : (xs.filter (fun x => !fp x)).length ≤ kg)
    (hf : (xs.filter fp).length ≤ kf) (x : α) :
    (x ∈ limit kg rank (xs.filter (fun x => !fp x)) ∨
     x ∈ limit kf rank (xs.filter fp)) ↔ x ∈ xs := by
  cases h : fp x <;> simp [limit, hg, hf, List.mem_filter, h]

-- Project the cancellation transfer onto whether the open map has any keys,
-- paired deletions, and outgoing trap-edge records. A stale empty stack can
-- keep its map key in C/Pion. Starting with no keys, that case is unreachable
-- on a block without inc.
inductive Op | inc | dec | barrier | branch | other
  deriving DecidableEq
structure Window where
  openKeys : Bool
  deleted : Nat
  outgoing : Nat
  deriving DecidableEq
def step (s : Window) : Op → Window
  | .inc => { s with openKeys := true }
  | .dec => if s.openKeys then { s with deleted := s.deleted + 2 } else s
  | .barrier => { s with openKeys := false }
  | .branch => if s.openKeys then { s with openKeys := false, outgoing := s.outgoing+1 } else s
  | .other => s

theorem no_open_no_effect (ops : List Op) (d e : Nat) (h : Op.inc ∉ ops) :
    ops.foldl step ⟨false, d, e⟩ = ⟨false, d, e⟩ := by
  induction ops with
  | nil => rfl
  | cons op ops ih =>
    have ht : Op.inc ∉ ops := fun hm => h (by simp [hm])
    cases op <;> simp_all [step]

-- Cursor in alignment-sized units. A rounded request fits wholly before
-- the end, and the next allocation starts past all bytes written by it.
theorem arena_disjoint (pos units cap align bytes : Nat)
    (fit : pos + units ≤ cap) (rounded : bytes ≤ units * align) :
    pos * align + bytes ≤ (pos + units) * align ∧
      (pos + units) * align ≤ cap * align := by
  constructor
  · simpa [Nat.add_mul] using Nat.add_le_add_left rounded (pos * align)
  · exact Nat.mul_le_mul_right align fit

end PionQbeCompileSpeedOpts
