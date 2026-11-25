/-
Equivalence theorems for the AArch64 address folding of Opt-Track H in
`vendor/qbe/arm64/isel.c` (`seladdr`), as emitted by the text backend
(`arm64/emit.c`) and the direct Mach-O encoder (`arm64/macho.c`), plus the
text / `--obj` emission-parity fix (`arm64_macho_needs_far`, `loadcon`).

Local stack slots (`localaddr`): a fixed local alloc is the frame cell
`fp + 16 + padding + 4 * slot`; `alloc + off` with `off % 4 = 0` is kept as
`SLOT(slot + off / 4)`, i.e. one `[x29, #off]` access without an address temp.

  1. `slot_fold`, `slot_same_access`: the folded slot is the same 64-bit
     address (frame padding and wrap-around included), so every load/store
     through it reads/writes the same cell.
  2. `slot_private_boundary`: `off / 4 < fn->slot - slot` keeps the folded
     slot inside the local area, below the first private spill slot that the
     spill-pair pass (`arm64_slotpair`) may merge.
  3. `slot_scaled_field`: an offset that is a multiple of the access width and
     below `4096 * width` round-trips through the scaled unsigned imm12
     (otherwise `fixarg` / `me_fixarg` fall back to `Oaddr`).

Single-use negative displacements (`imm9`): `sub base, k` (1 ≤ k ≤ 256) and
`add base, off` (-256 ≤ off < 0) become `ldur` / `stur [base, #off]`.

  4. `imm9_roundtrip`: the 9-bit two's-complement field decodes back to the
     displacement.
  5. `imm9_sub_address`, `imm9_add_address`, `imm9_sub_access`: both source
     forms compute the address the encoded instruction accesses.
  6. `imm9_field_unsigned32`: taking the field from the 32-bit truncation
     (`(uint32_t)off & 0x1ff`) gives the same 9 bits.

Emission parity (`emission-parity`):

  7. `imm19_signed_field`: a word displacement in `[-2^18, 2^18)` round-trips
     through the signed imm19 of `b.cond` / `cbz`, the range the direct
     encoder (and now the text path, via `arm64_macho_needs_far`) checks
     before choosing a short branch.
  8. `branch_same_edge`, `branch_targets`: the short `b.cond target` and the
     long `b.!cond +8; b target` pair take the same edge and land on the same
     targets.
  9. `logical_move`: `orr rd, zr, #imm` writes `imm`, so the explicit `orr`
     of `loadcon` is the value a `mov` alias of a bitmask immediate wrote.

Zero imports, complete kernel proofs without external solvers or
compiled-code evaluation; compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`.
-/

namespace PionQbeArm64AddrOpts

/-! ### Local stack slots -/

/-- Address of frame slot `index` (4-byte units above `fp + 16 + padding`). -/
def slot (fp padding index : Nat) : BitVec 64 :=
  BitVec.ofNat 64 (fp + 16 + padding + 4 * index)

/-- `slot + off` for a 4-byte aligned `off` is slot `base + off / 4`. -/
theorem slot_fold (fp padding base off : Nat) (aligned : off % 4 = 0) :
    slot fp padding base + BitVec.ofNat 64 off = slot fp padding (base + off / 4) := by
  unfold slot
  rw [← BitVec.ofNat_add]
  congr 1
  omega

/-- The folded slot stays below the first private spill slot. -/
theorem slot_private_boundary (base off firstSpill : Nat) (valid : base < firstSpill)
    (h : off / 4 < firstSpill - base) : base + off / 4 < firstSpill := by
  omega

/-- Any memory access through the folded slot is the original access. -/
theorem slot_same_access {α : Type} (access : BitVec 64 → α)
    (fp padding base off : Nat) (aligned : off % 4 = 0) :
    access (slot fp padding base + BitVec.ofNat 64 off) =
    access (slot fp padding (base + off / 4)) :=
  congrArg access (slot_fold fp padding base off aligned)

/-- A width-aligned byte offset below `4096 * size` round-trips through the
scaled unsigned imm12 field. -/
theorem slot_scaled_field (bytes size : Nat)
    (aligned : bytes % size = 0) (fits : bytes / size < 4096) :
    ((bytes / size) % 4096) * size = bytes := by
  rw [Nat.mod_eq_of_lt fits, Nat.div_mul_cancel (Nat.dvd_of_mod_eq_zero aligned)]

/-! ### Negative signed imm9 (`ldur` / `stur`) -/

/-- Decoding of the 9-bit two's-complement field `off mod 512`. -/
def imm9Decode (off : Int) : Int :=
  let field := off % 512
  if field < 256 then field else field - 512

theorem imm9_roundtrip (off : Int) (lo : -256 ≤ off) (hi : off < 0) :
    imm9Decode off = off := by
  dsimp [imm9Decode]
  split <;> omega

/-- `sub base, k` (1 ≤ k ≤ 256) is the address of `[base, #-k]`. -/
theorem imm9_sub_address (base : BitVec 64) (k : Int) (lo : 1 ≤ k) (hi : k ≤ 256) :
    base - BitVec.ofInt 64 k = base + BitVec.ofInt 64 (imm9Decode (-k)) := by
  rw [imm9_roundtrip (-k) (by omega) (by omega), BitVec.ofInt_neg]
  rw [BitVec.sub_eq_add_neg]

/-- `add base, off` (-256 ≤ off < 0) is the address of `[base, #off]`. -/
theorem imm9_add_address (base : BitVec 64) (off : Int) (lo : -256 ≤ off) (hi : off < 0) :
    base + BitVec.ofInt 64 off = base + BitVec.ofInt 64 (imm9Decode off) := by
  rw [imm9_roundtrip off lo hi]

/-- Any access through `sub base, k` is the encoded `ldur` / `stur` access. -/
theorem imm9_sub_access {α : Type} (step : BitVec 64 → α) (base : BitVec 64)
    (k : Int) (lo : 1 ≤ k) (hi : k ≤ 256) :
    step (base - BitVec.ofInt 64 k) = step (base + BitVec.ofInt 64 (imm9Decode (-k))) :=
  congrArg step (imm9_sub_address base k lo hi)

/-- The field taken from the 32-bit truncation is the same 9 bits. -/
theorem imm9_field_unsigned32 (off : Int) :
    (off % 4294967296) % 512 = off % 512 := by
  omega

/-! ### Emission parity: branch range and logical-immediate moves -/

def imm19Target (pc : BitVec 64) (words : Int) : BitVec 64 :=
  pc + BitVec.ofInt 64 (4 * words)

def shortBranch (pc : BitVec 64) (condition : Bool) (words : Int) : BitVec 64 :=
  if condition then imm19Target pc words else pc + 4

def longBranch (pc farTarget : BitVec 64) (inverted : Bool) : BitVec 64 :=
  if inverted then pc + 8 else farTarget

theorem imm19_signed_field (words : Int) (lo : -262144 ≤ words) (hi : words < 262144) :
    (if words % 524288 < 262144 then words % 524288 else words % 524288 - 524288) =
      words := by
  split <;> omega

inductive Edge where
  | taken
  | next
  deriving DecidableEq

theorem branch_same_edge (c : Bool) :
    (if c then Edge.taken else Edge.next) =
    (if !c then Edge.next else Edge.taken) := by
  cases c <;> rfl

theorem branch_targets (pc : BitVec 64) (c : Bool) (delta : Int) :
    (shortBranch pc c delta, longBranch pc (imm19Target pc delta) (!c)) =
    (if c then (imm19Target pc delta, imm19Target pc delta) else (pc + 4, pc + 8)) := by
  cases c <;> rfl

theorem logical_move {n : Nat} (mask : BitVec n) : (0 : BitVec n) ||| mask = mask := by
  simp

end PionQbeArm64AddrOpts
