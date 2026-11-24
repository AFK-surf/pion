/-
Formally verified equivalence theorems for the 6 QBE backend codegen
optimizations (x86-64 ELF64 + AArch64 emit/Mach-O).

Zero external dependencies, complete proofs, and pure kernel checks (no
external SAT/compiler trust axioms), compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`.
-/

namespace PionQbeCodegenOpts

abbrev W := BitVec 32
abbrev L := BitVec 64

/-! ### 1. x86-64 register compare against zero -> `test %r, %r` -/

/-- Result identity: `x - 0 = x &&& x`, so ZF/SF/PF match between `cmp $0, %r`
and `test %r, %r`. -/
theorem cmpTest (x : BitVec w) : x - 0 = x &&& x := by
  simp

/-- Carry and signed overflow flags for `cmp $0, %r` are always 0 (matching `test`),
for both 64-bit (`L`) and 32-bit (`W`) operands. -/
theorem cmpTestCarryOverflow (x : BitVec w) :
    (decide (x < 0) = false) ∧ (((x ^^^ 0) &&& (x ^^^ (x - 0))).msb = false) := by
  simp

theorem cmpTestCarryOverflow64 (x : L) :
    (decide (x < 0) = false) ∧ (((x ^^^ 0) &&& (x ^^^ (x - 0))).msb = false) :=
  cmpTestCarryOverflow x

theorem cmpTestCarryOverflow32 (x : W) :
    (decide (x < 0) = false) ∧ (((x ^^^ 0) &&& (x ^^^ (x - 0))).msb = false) :=
  cmpTestCarryOverflow x

/-! ### 2. x86-64 `shlq $1/$2/$3` folded into SIB scaled addressing -/

/-- 64-bit address arithmetic: `b + (i <<< k) + d = b + i * (1 <<< k) + d`
for `k ∈ {1, 2, 3}` (SIB scales 2, 4, 8). -/
theorem scaleAddr (b i d : L) (k : Nat) (h : k = 1 ∨ k = 2 ∨ k = 3) :
    b + (i <<< k) + d = b + i * (1 <<< k) + d := by
  have hsh : i <<< k = i * (1 <<< k) := by
    apply BitVec.eq_of_toNat_eq
    rcases h with rfl | rfl | rfl <;>
      simp [BitVec.toNat_shiftLeft, BitVec.toNat_mul] <;> omega
  rw [hsh]

/-- Enumerate legal SIB scales matching `1 <<< k` for `k ∈ {1, 2, 3}`. -/
def synthScale (k : Nat) : List Nat :=
  [1, 2, 4, 8].filter fun m => ((1 : L) <<< k) == BitVec.ofNat 64 m

theorem synthScaleChecks : [1, 2, 3].map synthScale = [[2], [4], [8]] := by
  decide

/-! ### 3. x86-64 intra-function short branch `rel8` encoding -/

/-- When `target - next` fits in signed 8-bit (`rel8`), replacing `rel32` with
`rel8` preserves the next PC on both taken and fall-through paths. -/
theorem shortBranch (next target : L) (take : Bool)
    (fits : ((target - next).truncate 8).signExtend 64 = target - next) :
    (if take then next + ((target - next).truncate 8).signExtend 64 else next) =
    (if take then target else next) := by
  rw [fits]
  cases take with
  | false => rfl
  | true =>
    simp only [↓reduceIte]
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_add, BitVec.toNat_sub]
    have h1 := next.isLt
    have h2 := target.isLt
    omega

/-! ### 4. x86-64 minimum-instruction multi-byte NOP alignment padding -/

/-- Abstract semantics of NOP padding: advances PC by total byte width and leaves
all architectural state untouched. -/
def runPad (widths : List Nat) (pc : Nat) (s : α) : Nat × α :=
  match widths with
  | [] => (pc, s)
  | w :: ws => runPad ws (pc + w) s

theorem padSum (ws : List Nat) (pc : Nat) (s : α) :
    runPad ws pc s = (pc + ws.sum, s) := by
  induction ws generalizing pc with
  | nil => simp [runPad]
  | cons w ws ih => simp [runPad, ih, Nat.add_assoc]

theorem padEquiv (a b : List Nat) (h : a.sum = b.sum) (pc : Nat) (s : α) :
    runPad a pc s = runPad b pc s := by
  rw [padSum, padSum, h]

/-- Optimal 1..9 B NOP decomposition for alignment gaps `n ≤ 15`. -/
def solvePad (n : Nat) : List Nat :=
  if n = 0 then [] else if n ≤ 9 then [n] else [9, n - 9]

theorem padTotal (n : Nat) : (solvePad n).sum = n := by
  unfold solvePad
  split <;> rename_i h
  · simp_all
  · split <;> simp_all <;> omega

theorem padEncodable (n : Nat) (h : n ≤ 15) :
    ∀ w ∈ solvePad n, 1 ≤ w ∧ w ≤ 9 := by
  unfold solvePad
  split
  · simp
  · split <;> simp_all <;> omega

theorem widthsBound (ws : List Nat) (h : ∀ w ∈ ws, w ≤ 9) :
    ws.sum ≤ 9 * ws.length := by
  induction ws with
  | nil => simp
  | cons w ws ih =>
    have head := h w (by simp)
    have tail := ih (by intro x hx; exact h x (by simp [hx]))
    simp
    omega

theorem padMinimal (n : Nat) (ws : List Nat) (h : ∀ w ∈ ws, w ≤ 9) (hn : ws.sum = n) :
    (solvePad n).length ≤ ws.length := by
  have lim := widthsBound ws h
  unfold solvePad
  split <;> simp_all
  split <;> simp_all <;> omega

/-! ### 5. x86-64 accumulator ALU `imm32` short encoding -/

/-- The short accumulator opcode `05 + 8*g` decodes to the exact same 3-bit ALU
operation group `g` as `81 /g`. -/
theorem accumulatorDecode (g : BitVec 3) :
    ((((g.zeroExtend 8) <<< 3) + 5 : BitVec 8) >>> 3).truncate 3 = g := by
  revert g
  decide

/-! ### 6. AArch64 prologue/epilogue callee-saved `stp`/`ldp` pairing -/

abbrev Slots := L → L

def put (m : Slots) (i x : L) : Slots :=
  fun j => if j = i then x else m j

/-- Descending `str r0, [x29, #(lo+8)]; str r1, [x29, #lo]` is equivalent to
`stp r1, r0, [x29, #lo]`. -/
theorem stpDescending (m : Slots) (lo hiVal loVal : L) :
    put (put m (lo + 8) hiVal) lo loVal =
    put (put m lo loVal) (lo + 8) hiVal := by
  have h : lo + 8 ≠ lo := by
    intro heq
    have hnat := congrArg BitVec.toNat heq
    have hlt := lo.isLt
    simp [BitVec.toNat_add] at hnat
    omega
  funext j
  by_cases a : j = lo <;> by_cases b : j = lo + 8 <;> simp_all [put]

/-- Descending `ldr r0, [x29, #(lo+8)]; ldr r1, [x29, #lo]` for distinct
registers `rdHi ≠ rdLo` is equivalent to `ldp r1, r0, [x29, #lo]`. -/
theorem ldpDescending (m regs : Slots) (lo rdHi rdLo : L) (hd : rdHi ≠ rdLo) :
    put (put regs rdHi (m (lo + 8))) rdLo (m lo) =
    put (put regs rdLo (m lo)) rdHi (m (lo + 8)) := by
  funext r
  by_cases a : r = rdHi <;> by_cases b : r = rdLo <;> simp_all [put]

end PionQbeCodegenOpts
