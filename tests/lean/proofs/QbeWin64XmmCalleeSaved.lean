/-
Win64 (Microsoft x64) frames in the QBE `amd64_win` backend
(`vendor/qbe/amd64/{all.h,winabi.c,targ.c,emit.c,isel.c}`, and the alloc
order of `{arm64,rv64}/isel.c`).

Microsoft x64: xmm0..xmm5 are volatile; xmm6..xmm15 are nonvolatile in all
128 bits. `amd64_winabi_rsave` lists only xmm0..xmm5, and
`amd64_winabi_emitfn` saves `xmm_save` = the xmm6..xmm14 of `fn->reg` plus
xmm15 when `winabi_uses_xmm15` finds one of the emitter's scratch writes.

Prologue (`winabi_prologue`), described by `.seh_*` unwind directives:
`push %rbp`?, GPR pushes, `sub $fsz, %rsp`, `mov %rsp, %rbp`? (frame offset
0), `movups %xmmN, off(%rsp)`. With `P` = `%rsp` after it (= `%rbp`), every
offset below is from `P`: slots `[0, 4 slot)`, `locsz = 4 ((slot + 3) & -4)`,
xmm k at `locsz + 16 k`, `fsz = locsz + 16 nxmm + 8 o`, GPR i at
`fsz + 8 i`, saved `%rbp` at `fsz + 8 nclob`, return address at
`R = fsz + 8 npush` (`npush = nclob + rbp`), caller slot `s >= 2` at
`4 s - 8 + R` (`slot()`).

  1. `frameDisjoint`: slots, xmm cells, GPR pushes, the saved %rbp and the
     caller area are pairwise disjoint; xmm cells are inside `[0, fsz)` with
     non-negative 16-byte aligned offsets (`.seh_savexmm` needs both).
  2. `rspAligned`: with `o = (npush + 1) mod 2`, `P` is 16-byte aligned for
     every frame, unconditionally (entry `%rsp` = 8 mod 16).
  3. `vastartSlot`: caller slot `4 + 2 m` is the home / stack slot of
     argument `m` (8 + 8 m past the return address), `lower_vastart`.
     With frame offset 0 the unwinder's frame base `%rbp - 16 * 0` is `P`
     however the body moved `%rsp` (dynalloc): the xmm cells and the
     `leaq fsz(%rbp), %rsp` epilogue use the same offsets.
  4. `allocAligned`, `oldOrderMisaligned`: fixed allocs laid out from the
     largest alignment down keep each offset a multiple of its alignment;
     the old ascending order put an alloc16 after an alloc4 at offset 4.
  5. `saveRestore`: storing the saved registers at distinct offsets, running
     any body that writes no save cell and no unsaved nonvolatile register,
     then loading them back from the same offsets leaves every nonvolatile
     register with its entry value, all 128 bits.
  6. `scannerCovers`, `writtenSaved`: `winabi_uses_xmm15` is true whenever the
     emitter writes xmm15 (Odiv with to = arg[1], a slot / memory to slot copy
     (also from a 2-address conversion), a floating-point swap), so every
     nonvolatile register the function writes is in `xmm_save`.
  7. `callerView`: `rsave` holds xmm0..xmm5 and no xmm6..xmm15, so a call
     leaves values in xmm6..xmm14 to the callee, which preserves them (5).

The models follow the C arithmetic and data; they do not formalize x86.
Complete kernel proofs, no external trust axioms.
-/
import Std

namespace PionQbeWin64XmmCalleeSaved

/-! ### Frame layout (`winabi_framesz`, `slot()`) -/

def locsz (slot : Nat) : Nat := 4 * ((slot + 3) / 4 * 4)

def pad (npush : Nat) : Nat := (npush + 1) % 2

def fsz (slot nxmm npush : Nat) : Nat := locsz slot + 16 * nxmm + 8 * pad npush

/-- Return address offset from `P`. -/
def retAt (slot nxmm nclob rbp : Nat) : Nat := fsz slot nxmm (nclob + rbp) + 8 * (nclob + rbp)

/-- `slot(s)` for a caller slot `s' = -s >= 2`. -/
def callerSlot (slot nxmm nclob rbp s' : Nat) : Nat := 4 * s' - 8 + retAt slot nxmm nclob rbp

theorem locsz16 (slot : Nat) : locsz slot % 16 = 0 ∧ 4 * slot ≤ locsz slot := by
  unfold locsz; omega

def InSlots (slot a : Nat) : Prop := a < 4 * slot
def InXmm (slot k a : Nat) : Prop := locsz slot + 16 * k ≤ a ∧ a < locsz slot + 16 * (k + 1)
def InGpr (F i a : Nat) : Prop := F + 8 * i ≤ a ∧ a < F + 8 * (i + 1)

theorem frameDisjoint (slot nxmm nclob rbp : Nat) :
    let F := fsz slot nxmm (nclob + rbp)
    let R := retAt slot nxmm nclob rbp
    (∀ k a, k < nxmm → InXmm slot k a → ¬ InSlots slot a) ∧
    (∀ k j a, k < nxmm → j < nxmm → k ≠ j → InXmm slot k a → ¬ InXmm slot j a) ∧
    (∀ k i a, k < nxmm → i < nclob → InXmm slot k a → ¬ InGpr F i a) ∧
    (∀ i a, i < nclob → InGpr F i a → ¬ InSlots slot a) ∧
    (∀ k, k < nxmm → (locsz slot + 16 * k) % 16 = 0 ∧ locsz slot + 16 * (k + 1) ≤ F) ∧
    (∀ i, i < nclob → F + 8 * (i + 1) ≤ F + 8 * nclob) ∧
    (rbp = 1 → F + 8 * nclob + 8 ≤ R) ∧
    (∀ s', 2 ≤ s' → R ≤ callerSlot slot nxmm nclob rbp s') ∧
    (∀ a, a < F + 8 * nclob + 8 * rbp → a < R) := by
  intro F R
  have h := locsz16 slot
  have hF : F = locsz slot + 16 * nxmm + 8 * pad (nclob + rbp) := rfl
  have hR : R = F + 8 * (nclob + rbp) := rfl
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · intro k a _ hx hl
    simp only [InXmm, InSlots] at hx hl
    omega
  · intro k j a _ _ hkj hx hy
    simp only [InXmm] at hx hy
    omega
  · intro k i a hk _ hx hg
    simp only [InXmm, InGpr] at hx hg
    omega
  · intro i a _ hg hl
    simp only [InGpr, InSlots] at hg hl
    omega
  · intro k hk
    omega
  · intro i hi
    omega
  · intro h1
    omega
  · intro s' h2
    simp only [callerSlot]
    omega
  · intro a ha
    omega

/-- `P` = entry `%rsp` - `8 npush` - `fsz` is 16-byte aligned, given the
entry `%rsp` is 8 mod 16, for every frame. -/
theorem rspAligned (slot nxmm npush entry : Nat) (he : entry % 16 = 8)
    (hle : 8 * npush + fsz slot nxmm npush ≤ entry) :
    (entry - 8 * npush - fsz slot nxmm npush) % 16 = 0 := by
  have h := locsz16 slot
  unfold fsz pad at *
  omega

/-- Slots of an alloc16 (unit offsets that are multiples of 4) are 16-byte
aligned from the aligned `P`. -/
theorem slot16 (P s : Nat) (hP : P % 16 = 0) (hs : s % 4 = 0) : (P + 4 * s) % 16 = 0 := by
  omega

theorem vastartSlot (slot nxmm nclob rbp m : Nat) :
    callerSlot slot nxmm nclob rbp (4 + 2 * m) = retAt slot nxmm nclob rbp + 8 + 8 * m := by
  simp only [callerSlot]
  omega

/-! ### Fixed alloc slots (`isel.c`) -/

/-- An alloc as (log2 alignment, size in bytes rounded to the alignment). -/
def offsets : List (Nat × Nat) → Nat → List Nat
  | [], _ => []
  | (_, sz) :: t, o => o :: offsets t (o + sz)

theorem pow_dvd_of_le {e f : Nat} (h : e ≤ f) : 2 ^ e ∣ 2 ^ f :=
  Nat.pow_dvd_pow 2 h

/-- Laid out with non-increasing alignments (each size a multiple of its own
alignment) from an offset aligned for all of them, every alloc starts at a
multiple of its alignment. -/
theorem allocAligned : ∀ (l : List (Nat × Nat)) (o : Nat),
    (∀ p ∈ l, 2 ^ p.1 ∣ p.2) →
    l.Pairwise (fun a b => b.1 ≤ a.1) →
    (∀ p ∈ l, 2 ^ p.1 ∣ o) →
    ∀ x ∈ List.zip l (offsets l o), 2 ^ x.1.1 ∣ x.2
  | [], _, _, _, _, x, hx => by simp [offsets] at hx
  | q :: t, o, hs, hp, ho, x, hx => by
    simp only [offsets, List.zip_cons_cons, List.mem_cons] at hx
    have hq := List.mem_cons_self (a := q) (l := t)
    rcases hx with rfl | hx
    · exact ho q hq
    · have hp' := List.pairwise_cons.mp hp
      refine allocAligned t (o + q.2) (fun p hp2 => hs p (List.mem_cons_of_mem _ hp2)) hp'.2
        ?_ x hx
      intro p hpt
      have hle : p.1 ≤ q.1 := hp'.1 p hpt
      exact Nat.dvd_add (Nat.dvd_trans (pow_dvd_of_le hle) (ho q hq))
        (Nat.dvd_trans (pow_dvd_of_le hle) (hs q hq))

/-- The old order (alignment ascending): `alloc4 4` then `alloc16 16` put
the alloc16 at offset 4. -/
theorem oldOrderMisaligned : offsets [(2, 4), (4, 16)] 0 = [0, 4] ∧ ¬ (2 ^ 4 ∣ 4) := by
  decide

/-- Padding the total slot area to a multiple of `2^maxE` (where every alloc
has `p.1 ≤ maxE`, plus any 16-byte-aligned spill extension when `maxE ≤ 4`)
keeps offsets aligned from both ends: bottom-up (`o`, e.g. `amd64_win`) and
top-down (`total - o`, e.g. `amd64_sysv` rbp, `arm64`, `rv64`). -/
theorem allocAlignedBothEnds (l : List (Nat × Nat)) (maxE total : Nat)
    (hs : ∀ p ∈ l, 2 ^ p.1 ∣ p.2)
    (hp : l.Pairwise (fun a b => b.1 ≤ a.1))
    (hmax : ∀ p ∈ l, p.1 ≤ maxE)
    (htot : 2 ^ maxE ∣ total) :
    ∀ x ∈ List.zip l (offsets l 0),
      2 ^ x.1.1 ∣ x.2 ∧ (x.2 ≤ total → 2 ^ x.1.1 ∣ (total - x.2)) := by
  intro x hx
  have hbot : 2 ^ x.1.1 ∣ x.2 :=
    allocAligned l 0 hs hp (fun p _ => Nat.dvd_zero _) x hx
  refine ⟨hbot, fun _ => ?_⟩
  have hmem : x.1 ∈ l := (List.of_mem_zip hx).1
  have hdiv_tot : 2 ^ x.1.1 ∣ total :=
    Nat.dvd_trans (pow_dvd_of_le (hmax x.1 hmem)) htot
  exact Nat.dvd_sub hdiv_tot hbot

/-! ### 128-bit save / restore -/

abbrev V := BitVec 128

/-- `movups %xmmR, OFF(base)` for every `(R, OFF)`. -/
def stores (l : List (Nat × Int)) (reg : Nat → V) (mem : Int → V) : Int → V :=
  l.foldr (fun p m => fun a => if a = p.2 then reg p.1 else m a) mem

/-- `movups OFF(base), %xmmR` for every `(R, OFF)`. -/
def loads (l : List (Nat × Int)) (mem : Int → V) (reg : Nat → V) : Nat → V :=
  l.foldr (fun p r => fun x => if x = p.1 then mem p.2 else r x) reg

theorem stores_spec (l : List (Nat × Int)) (reg : Nat → V) (mem : Int → V)
    (h : (l.map Prod.snd).Nodup) (p : Nat × Int) (hp : p ∈ l) :
    stores l reg mem p.2 = reg p.1 := by
  induction l with
  | nil => cases hp
  | cons q t ih =>
    simp only [List.map_cons, List.nodup_cons] at h
    simp only [stores, List.foldr_cons]
    rcases List.mem_cons.mp hp with rfl | ht
    · simp
    · have hne : p.2 ≠ q.2 := by
        intro he
        exact h.1 (he ▸ List.mem_map_of_mem ht)
      simp only [hne, ite_false]
      exact ih h.2 ht

theorem loads_spec (l : List (Nat × Int)) (mem : Int → V) (reg : Nat → V)
    (h : (l.map Prod.fst).Nodup) (p : Nat × Int) (hp : p ∈ l) :
    loads l mem reg p.1 = mem p.2 := by
  induction l with
  | nil => cases hp
  | cons q t ih =>
    simp only [List.map_cons, List.nodup_cons] at h
    simp only [loads, List.foldr_cons]
    rcases List.mem_cons.mp hp with rfl | ht
    · simp
    · have hne : p.1 ≠ q.1 := by
        intro he
        exact h.1 (he ▸ List.mem_map_of_mem ht)
      simp only [hne, ite_false]
      exact ih h.2 ht

theorem loads_other (l : List (Nat × Int)) (mem : Int → V) (reg : Nat → V)
    (x : Nat) (hx : x ∉ l.map Prod.fst) : loads l mem reg x = reg x := by
  induction l with
  | nil => rfl
  | cons q t ih =>
    simp only [List.map_cons, List.mem_cons, not_or] at hx
    simp only [loads, List.foldr_cons, hx.1, ite_false]
    exact ih hx.2

/-- Entry registers `reg0`, memory `mem0`; the prologue stores `l`; the body
yields `reg1`, `mem1` (any values: arbitrary 128-bit writes to any register,
volatile or saved); the epilogue loads `l` back. If the body leaves the save
cells alone and writes no nonvolatile register outside `l`, every
nonvolatile register returns with its entry bits. -/
theorem saveRestore (hi : Nat → Prop) (l : List (Nat × Int))
    (reg0 reg1 : Nat → V) (mem0 mem1 : Int → V)
    (hr : (l.map Prod.fst).Nodup) (ho : (l.map Prod.snd).Nodup)
    (hcells : ∀ p ∈ l, mem1 p.2 = stores l reg0 mem0 p.2)
    (hunsaved : ∀ x, hi x → x ∉ l.map Prod.fst → reg1 x = reg0 x) :
    ∀ x, hi x → loads l mem1 reg1 x = reg0 x := by
  intro x hx
  by_cases hm : x ∈ l.map Prod.fst
  · obtain ⟨p, hp, rfl⟩ := List.mem_map.mp hm
    rw [loads_spec l mem1 reg1 hr p hp, hcells p hp, stores_spec l reg0 mem0 ho p hp]
  · rw [loads_other l mem1 reg1 x hm]
    exact hunsaved x hx hm

/-! ### Which nonvolatile registers are saved (`winabi_uses_xmm15`) -/

inductive Ref where
  | none
  | tmp (r : Nat)
  | slot (s : Int)
  | mem (m : Nat)
  | con (c : Nat)
  deriving DecidableEq

def Ref.isSlot : Ref → Bool
  | .slot _ => true
  | _ => false

def Ref.isSlotOrMem : Ref → Bool
  | .slot _ => true
  | .mem _ => true
  | _ => false

inductive Op where
  | div | copy | swap | other
  deriving DecidableEq

structure Ins where
  op : Op
  fp : Bool
  to : Ref
  a0 : Ref
  a1 : Ref

/-- `emitcopy(to, a0)` reaching the Ocopy slot / memory to slot case. -/
def slotCopy (i : Ins) : Bool :=
  i.to != .none && i.a0 != .none && i.to != i.a0 && i.to.isSlot && i.a0.isSlotOrMem

/-- Where `emitins` writes `TMP(XMM0+15)`: Odiv with `to == arg[1]`, an
Ocopy (direct or from the 2-address conversion of another op) from a slot or
memory into a slot, and a floating-point Oswap. -/
def emitWrites15 (i : Ins) : Bool :=
  (i.op == .div && i.to == i.a1) || (i.op == .swap && i.fp) || slotCopy i

/-- One iteration of `winabi_uses_xmm15`. -/
def scan (i : Ins) : Bool :=
  (i.op == .div && i.to == i.a1) || (i.op == .swap && i.fp) ||
  (!(i.to == .none || i.a0 == .none || i.to == i.a0) && i.to.isSlot && i.a0.isSlotOrMem)

def usesXmm15 (fn : List Ins) : Bool := fn.any scan

theorem scannerCovers (fn : List Ins) (i : Ins) (hi : i ∈ fn)
    (hw : emitWrites15 i = true) : usesXmm15 fn = true := by
  apply List.any_eq_true.mpr
  refine ⟨i, hi, ?_⟩
  revert hw
  simp only [emitWrites15, scan, slotCopy]
  cases i.to <;> cases i.a0 <;> simp_all

/-- Register numbers of `amd64/all.h`. -/
def RAX := 1
def RCX := 2
def RDX := 3
def R8 := 6
def R9 := 7
def R10 := 8
def R11 := 9
def XMM0 := 17
def XMM5 := 22
def XMM6 := 23
def XMM14 := 31
def XMM15 := 32

/-- `xmm_save`: the xmm6..xmm14 of `fn->reg` plus xmm15 if scanned. -/
def xmmSave (reg : Nat → Bool) (fn : List Ins) (x : Nat) : Bool :=
  (XMM6 ≤ x && x ≤ XMM14 && reg x) || (x == XMM15 && usesXmm15 fn)

/-- The function writes the registers the allocator assigned (`fn->reg`,
xmm15 excluded: NFPR reserves it) and xmm15 at each scratch use. -/
def Written (reg : Nat → Bool) (fn : List Ins) (x : Nat) : Prop :=
  (reg x = true ∧ x ≠ XMM15) ∨ (x = XMM15 ∧ ∃ i ∈ fn, emitWrites15 i = true)

theorem writtenSaved (reg : Nat → Bool) (fn : List Ins) (x : Nat)
    (hhi : XMM6 ≤ x ∧ x ≤ XMM15) (hw : Written reg fn x) : xmmSave reg fn x = true := by
  simp only [xmmSave, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq]
  rcases hw with ⟨hr, hne⟩ | ⟨rfl, i, hi, hwi⟩
  · left
    refine ⟨⟨hhi.1, ?_⟩, hr⟩
    simp only [XMM14, XMM15] at hhi hne ⊢
    omega
  · right
    exact ⟨rfl, scannerCovers fn i hi hwi⟩

/-! ### Caller view (`amd64_winabi_rsave`, `amd64_winabi_xclob`) -/

def rsave : List Nat := [RCX, RDX, R8, R9, R10, R11, RAX, 17, 18, 19, 20, 21, 22]
def xclob : List Nat := [23, 24, 25, 26, 27, 28, 29, 30, 31, 32]

/-- A call clobbers exactly the `rsave` registers. -/
def afterCall (reg junk : Nat → V) (x : Nat) : V := if x ∈ rsave then junk x else reg x

theorem callerView :
    rsave.length = 7 + 6 ∧ xclob.length = 10 ∧
    (∀ x ∈ rsave, XMM0 ≤ x → x ≤ XMM5) ∧
    (∀ x ∈ xclob, x ∉ rsave) ∧
    (∀ x, XMM6 ≤ x → x ≤ XMM15 → x ∈ xclob) ∧
    (∀ (reg junk : Nat → V) x, XMM6 ≤ x → x ≤ XMM14 → afterCall reg junk x = reg x) := by
  refine ⟨by decide, by decide, by decide, by decide, ?_, ?_⟩
  · intro x h1 h2
    simp only [XMM6, XMM15] at h1 h2
    simp only [xclob, List.mem_cons, List.mem_nil_iff, or_false]
    omega
  · intro reg junk x h1 h2
    have : x ∉ rsave := by
      simp only [XMM6, XMM14] at h1 h2
      simp only [rsave, RCX, RDX, R8, R9, R10, R11, RAX, List.mem_cons, List.mem_nil_iff,
        or_false]
      omega
    simp [afterCall, this]

end PionQbeWin64XmmCalleeSaved
