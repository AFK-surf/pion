/-
Soundness of the strict two-lane `Double` SLP pass in the vendored QBE
(`vendor/qbe/slp.h`, `spill.c`, `rega.c`, `{amd64,arm64}/emit.c`,
`amd64/elf.c`, `arm64/macho.c`; regression test
`tests/e2e/p127_qbe_double_simd_slp`).

After instruction selection on `amd64_sysv` / `arm64_apple`, a bounded
function with paired 8-byte `Double` writes to one base is replayed as a
private copy in which corresponding `add` / `sub` / `mul` / `load` / `store`
pairs become one 128-bit operation (`Ovadd`, `Ovsub`, `Ovmul`, `Ovmullane`,
`Ovload`, `Ovstore`, `Ovsum`). The copy and the original scalar allocation
are joined behind an entry test of MXCSR / FPCR (`Otrapmask`).

  1. Lanes (`ordered`, `earlyRead`, `frame`): one packet operation computes
     the same lane results as the two ordered scalar operations it replaces
     (same operand order, so the same NaN payloads), its sticky exception
     flags are those of the scalar sequence, a write to one address never
     changes a read of another, and a 16-byte rounded frame stays aligned.
  2. Schedule (`preserves`, `disjoint`): the scheduler only swaps adjacent
     independent operations, which preserves the final state of any
     sequence, and writes to two distinct addresses commute.
  3. Frame (`allocate`, `separate`, `lowOnly`, `callReload`): a vector home
     is a fresh aligned quartet of four-byte words past every scalar slot,
     so it overlaps no scalar home; AAPCS64 may change the high half of a
     callee-saved D register across a call, which is why a packet live
     across a call is kept in its private slot, and both lanes reload intact.
  4. Dispatch (`maskedVector`, `trapScalar`): when every floating-point
     exception is masked (MXCSR bits 7..12 all set / FPCR trap enables
     0x9F00 all clear) the entry test runs the packet graph, whose results
     and sticky flags equal the scalar sequence; when any trap is enabled it
     runs the retained scalar graph unchanged, which keeps the first
     exception and the writes completed before it.

The floating-point operation is a parameter (rounding direction, masks and
NaN policy fixed by the target); instruction encodings, the C implementation
of the dependence edges and the ABIs are covered by the p127 end-to-end test.
-/
import Std

namespace PionQbeDoubleSimdSlp

/-! ## 1. Lanes -/

abbrev W := BitVec 64
abbrev Status := BitVec 32
/-- One masked scalar operation: its result and the sticky exception bits it
raises. Masks, rounding direction and NaN policy are fixed parameters. -/
abbrev Binary := W → W → W × Status

structure V where
  lo : W
  hi : W

/-- A two-lane packet operation. -/
def packet (f : Binary) (a b : V) : V × Status :=
  let x := f a.lo b.lo
  let y := f a.hi b.hi
  (⟨x.1, y.1⟩, x.2 ||| y.2)

theorem ordered (f : Binary) (a b : V) (s : Status) :
    (packet f a b).1.lo = (f a.lo b.lo).1 ∧
    (packet f a b).1.hi = (f a.hi b.hi).1 ∧
    (s ||| (packet f a b).2) = ((s ||| (f a.lo b.lo).2) ||| (f a.hi b.hi).2) := by
  refine ⟨rfl, rfl, ?_⟩
  simp [packet, BitVec.or_assoc]

def write (s : Nat → W) (p : Nat) (v : W) : Nat → W :=
  fun i => if i = p then v else s i

theorem earlyRead (s : Nat → W) (p q : Nat) (h : q ≠ p) (v : W) :
    write s p v q = s q := by
  simp [write, h]

def align16 (bytes : Nat) := ((bytes + 15) / 16) * 16

theorem frame (bytes : Nat) :
    bytes ≤ align16 bytes ∧ align16 bytes % 16 = 0 ∧
    align16 bytes + 16 ≤ align16 (align16 bytes + 16) := by
  unfold align16
  omega

/-! ## 2. Schedule -/

def run {S : Type} : List (S → S) → S → S
  | [], s => s
  | f :: fs, s => run fs (f s)

/-- Reorder adjacent independent instructions or replace an equivalent
sequence. -/
inductive Changes {S : Type} : List (S → S) → List (S → S) → Prop where
  | same (xs) : Changes xs xs
  | swap (f g : S → S) (tail) (indep : ∀ s, g (f s) = f (g s)) :
      Changes (f :: g :: tail) (g :: f :: tail)
  | keepHead (f : S → S) {a b} (h : Changes a b) : Changes (f :: a) (f :: b)
  | chain {a b c} (h : Changes a b) (k : Changes b c) : Changes a c

theorem preserves {S : Type} {a b : List (S → S)} (h : Changes a b) :
    ∀ s, run a s = run b s := by
  induction h with
  | same => intro s; rfl
  | swap f g tail indep => intro s; simp only [run, indep s]
  | keepHead f _ ih => intro s; exact ih (f s)
  | chain _ _ ih ik => intro s; exact (ih s).trans (ik s)

theorem disjoint (m : Nat → W) (a b : Nat) (x y : W) (h : a ≠ b) :
    write (write m a x) b y = write (write m b y) a x := by
  funext i
  by_cases ha : i = a <;> by_cases hb : i = b <;> simp_all [write]

/-! ## 3. Frame -/

/-- Indices in spill.c count four-byte words. -/
def start (locals high : Nat) := (locals + high + 3) / 4 * 4

theorem allocate (locals low high : Nat) (hole : low ≤ high) :
    locals + low ≤ start locals high ∧ locals + high ≤ start locals high ∧
    start locals high % 4 = 0 ∧
    (start locals high + 4 - locals) + locals = start locals high + 4 := by
  unfold start
  omega

theorem separate (locals high old new : Nat)
    (h : old < locals + high) (n : start locals high ≤ new) : old ≠ new := by
  unfold start at n
  omega

abbrev Lane := BitVec 64
abbrev Vector := Lane × Lane

/-- The ABI permits a callee to overwrite the high half of a nonvolatile D
register. -/
def clobberHigh (reg : Vector) (fresh : Lane) : Vector := (reg.1, fresh)

theorem lowOnly (reg : Vector) (fresh : Lane) (different : fresh ≠ reg.2) :
    clobberHigh reg fresh ≠ reg := by
  intro h
  exact different (congrArg Prod.snd h)

def save (stack : Nat → Lane) (slot : Nat) (v : Vector) (i : Nat) : Lane :=
  if i = slot then v.1 else if i = slot + 1 then v.2 else stack i

theorem callReload (stack : Nat → Lane) (slot : Nat) (v : Vector)
    (afterCall : Nat → Lane)
    (privateSlot : ∀ i, slot ≤ i → i ≤ slot + 1 → afterCall i = save stack slot v i) :
    (afterCall slot, afterCall (slot + 1)) = v := by
  rw [privateSlot slot (by omega) (by omega), privateSlot (slot + 1) (by omega) (by omega)]
  simp [save]

/-! ## 4. Dispatch on the trap enables (`Otrapmask`, `slpversion`) -/

inductive Target where
  | amd64
  | arm64

/-- The entry test: `stmxcsr; andl $0x1F80; cmpl $0x1F80` on amd64 (all six
exception mask bits set), `mrs fpcr; tst #0x9F00` on arm64 (all trap enable
bits clear). `true` selects the packet graph. -/
def trapsOff : Target → BitVec 32 → Bool
  | .amd64, csr => (csr &&& 0x1F80#32) == 0x1F80#32
  | .arm64, cr => (cr &&& 0x9F00#32) == 0#32

/-- The function produced by `slpversion`: a new entry block whose `Jjfieq`
branches to the packet graph or to the retained scalar graph. -/
def entry {S R : Type} (t : Target) (csr : BitVec 32) (packetArm scalarArm : S → R)
    (s : S) : R :=
  if trapsOff t csr then packetArm s else scalarArm s

/-- The two original scalar operations, low lane first, accumulating sticky
flags. -/
def scalarPair (f : Binary) (a b : V) (st : Status) : V × Status :=
  let x := f a.lo b.lo
  let y := f a.hi b.hi
  (⟨x.1, y.1⟩, (st ||| x.2) ||| y.2)

def packetPair (f : Binary) (a b : V) (st : Status) : V × Status :=
  ((packet f a b).1, st ||| (packet f a b).2)

/-- All exceptions masked: the entry selects the packet graph, and its lane
results and sticky flags equal those of the scalar graph. -/
theorem maskedVector (f : Binary) (t : Target) (csr : BitVec 32)
    (h : trapsOff t csr = true) (a b : V) (st : Status) :
    entry t csr (packetPair f a b) (scalarPair f a b) st = packetPair f a b st ∧
    packetPair f a b st = scalarPair f a b st := by
  refine ⟨by simp [entry, h], ?_⟩
  simp [packetPair, scalarPair, packet, BitVec.or_assoc]

/-- Any trap enabled: the entry runs the retained scalar graph unchanged, so
the first trapping operation and every write before it are those of the
original scalar code, whatever the packet graph would do. -/
theorem trapScalar {S R : Type} (t : Target) (csr : BitVec 32)
    (h : trapsOff t csr = false) (packetArm scalarArm : S → R) (s : S) :
    entry t csr packetArm scalarArm s = scalarArm s := by
  simp [entry, h]

end PionQbeDoubleSimdSlp
