/-
Formally verified equivalence theorems for the AArch64 compiler-private
spill-slot pairing in `vendor/qbe/arm64/isel.c` (`arm64_slotpair`), used by
both the text emitter (`emit.c`) and the direct Mach-O encoder (`macho.c`):
two adjacent `str`/`ldr` (or slot `copy`) of the same integer class on
adjacent private spill slots become one `stp`/`ldp [x29, #off]`.

  1. `adjacent_store`: two w-byte stores to `[a, a+w)` and `[a+w, a+2w)`, in
     either program order, write exactly what one `stp lo, hi, [a]` writes.
  2. `adjacent_load`: two loads into distinct registers commute, so one
     `ldp lo, hi` (low-address cell into `Rt`) equals both program orders.
     The `d0 ≠ d1` hypothesis is the `ldp Rt == Rt2` (UNPREDICTABLE) guard.
  3. `slotPairEncoding`: a w-aligned offset with `off/w ≤ 63` round-trips
     through the scaled 7-bit immediate (positive half only).
  4. `pairWord_fields`: the 32-bit instruction word
     `base | L<<22 | imm7<<15 | Rt2<<10 | Rn<<5 | Rt` decodes back to each
     field, i.e. the fields occupy disjoint bit ranges.

Zero external dependencies, complete kernel proofs without external
solvers or compiled-code evaluation, compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`.
-/

namespace PionQbeArm64SlotPairs

/-! ### Memory: byte-addressed private stack cells -/

def storeBytes (m : Nat → BitVec 8) (base width : Nat) (v : Nat → BitVec 8) :
    Nat → BitVec 8 :=
  fun j => if base ≤ j ∧ j < base + width then v (j - base) else m j

def storePair (m : Nat → BitVec 8) (base w : Nat) (lo hi : Nat → BitVec 8) :
    Nat → BitVec 8 :=
  fun j => if base ≤ j ∧ j < base + 2 * w then
    if j < base + w then lo (j - base) else hi (j - (base + w)) else m j

/-- Two adjacent stores, in ascending or descending program order, equal one
`stp` whose low-address operand (`Rt`) is the store to the lower cell. -/
theorem adjacent_store (m : Nat → BitVec 8) (a w : Nat) (lo hi : Nat → BitVec 8)
    (descending : Bool) :
    (if descending then storeBytes (storeBytes m (a + w) w hi) a w lo
     else storeBytes (storeBytes m a w lo) (a + w) w hi) = storePair m a w lo hi := by
  funext j
  cases descending <;> simp [storeBytes, storePair] <;>
    (repeat' split) <;> first | rfl | omega

/-- Reading memory cells outside the pair is unaffected by `stp`. -/
theorem storePair_frame (m : Nat → BitVec 8) (a w j : Nat) (lo hi : Nat → BitVec 8)
    (h : j < a ∨ a + 2 * w ≤ j) : storePair m a w lo hi j = m j := by
  have hn : ¬(a ≤ j ∧ j < a + 2 * w) := by omega
  simp [storePair, hn]

/-! ### Registers -/

def write (r : Nat → α) (d : Nat) (v : α) : Nat → α :=
  fun x => if x = d then v else r x

/-- Two loads into distinct registers commute (independent of which cell is
lower), so one `ldp` equals the original instruction pair. -/
theorem adjacent_load (r : Nat → BitVec 64) (d0 d1 : Nat) (h : d0 ≠ d1)
    (v0 v1 : BitVec w) :
    write (write r d1 (v1.zeroExtend 64)) d0 (v0.zeroExtend 64) =
    write (write r d0 (v0.zeroExtend 64)) d1 (v1.zeroExtend 64) := by
  funext i
  by_cases a : i = d0 <;> by_cases b : i = d1 <;> simp_all [write]

/-- Without the `d0 ≠ d1` guard the two program orders disagree whenever the
loaded values differ: the guard is necessary, not just sufficient. -/
theorem same_dest_order_matters (r : Nat → BitVec 64) (d : Nat) (v0 v1 : BitVec 64)
    (h : v0 ≠ v1) :
    write (write r d v1) d v0 ≠ write (write r d v0) d v1 := by
  intro e
  have := congrFun e d
  simp [write] at this
  exact h this

/-! ### Scaled immediate -/

/-- A w-aligned offset with `off / w ≤ 63` is exactly representable in the
signed scaled `imm7` field of `stp`/`ldp` (positive half). -/
theorem slotPairEncoding (offset width : Nat) (hw : width = 4 ∨ width = 8)
    (ha : offset % width = 0) (hr : offset / width ≤ 63) :
    (offset / width) % 128 * width = offset ∧ offset / width < 64 := by
  rcases hw with rfl | rfl <;> omega

/-- The emitted offset `16 + padding + 4*s` of a slot is the same for both
emitters (`slot()` in emit.c, `me_slot()` in macho.c, `s ≥ 0`), and two slots
are adjacent w-byte cells exactly when their indices differ by `w / 4`. -/
theorem slotAdjacent (padding s0 s1 w : Nat) (hw : w = 4 ∨ w = 8) :
    16 + padding + 4 * s1 = (16 + padding + 4 * s0) + w ↔ s1 = s0 + w / 4 := by
  rcases hw with rfl | rfl <;> omega

/-! ### Instruction word -/

/-- `stp`/`ldp` (signed offset) word as built by `macho.c`:
`base | L<<22 | imm7<<15 | Rt2<<10 | Rn<<5 | Rt`, with
`base = 0xa9000000` (X) or `0x29000000` (W). -/
def pairWord (base l imm7 rt2 rn rt : Nat) : Nat :=
  base + l * 2^22 + imm7 * 2^15 + rt2 * 2^10 + rn * 2^5 + rt

/-- Every field decodes back from the word: the fields are disjoint and the
opcode bits above bit 23 are untouched. -/
theorem pairWord_fields (base l imm7 rt2 rn rt : Nat)
    (hb : base % 2^23 = 0) (hl : l < 2) (hi : imm7 < 2^7)
    (h2 : rt2 < 2^5) (hn : rn < 2^5) (ht : rt < 2^5) :
    let x := pairWord base l imm7 rt2 rn rt
    x % 2^5 = rt ∧ x / 2^5 % 2^5 = rn ∧ x / 2^10 % 2^5 = rt2 ∧
    x / 2^15 % 2^7 = imm7 ∧ x / 2^22 % 2 = l ∧ x / 2^23 = base / 2^23 := by
  simp only [pairWord]
  omega

/-- The two opcode bases differ only in bit 31 (`sf`/`opc<1>`: X vs W) and have
bit 22 (L) clear, so `| L<<22` selects `ldp` vs `stp`. -/
theorem pairBases :
    (0xa9000000 : Nat) % 2^23 = 0 ∧ (0x29000000 : Nat) % 2^23 = 0 ∧
    (0xa9000000 : Nat) = 0x29000000 + 2^31 := by
  decide

end PionQbeArm64SlotPairs
