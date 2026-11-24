/-
Equivalence theorems for the two x86-64 peepholes that `amd64_elf_fn`
(`vendor/qbe/amd64/elf.c`) applies under one shared intrablock
arithmetic-FLAGS liveness scan (`flags_dead_before`):

  1. `copy 0` into a GPR: `xor %r32, %r32` instead of `mov $0, %r32`;
  2. integer `add` with a destination distinct from both operands:
     `lea (a,v), to` / `lea disp32(a), to` instead of `mov a, to; add v, to`.

Machine model: 16 GPRs of 64 bits plus an arbitrary FLAGS value. Both
rewrites may only differ from the original in FLAGS, and the emitter fires
them only where FLAGS are dead (a later full write, a call or `ret`
precedes their next read), so the observation is the register file.
Writing a 32-bit register zero-extends into the full 64-bit register.

Complete kernel proofs: no external SAT/compiler trust axioms.
-/

namespace PionQbeX86ZeroLea

structure St (F : Type) where
  regs : Nat → BitVec 64
  flags : F

def wr (r : Nat → BitVec 64) (d : Nat) (v : BitVec 64) : Nat → BitVec 64 :=
  fun x => if x = d then v else r x

/-- 32-bit register write: the result is zero-extended to 64 bits. -/
def wr32 (r : Nat → BitVec 64) (d : Nat) (v : BitVec 32) : Nat → BitVec 64 :=
  wr r d (v.zeroExtend 64)

/-! ### Truncation lemmas -/

theorem trunc_add (a b : BitVec 64) :
    (a + b).truncate 32 = a.truncate 32 + b.truncate 32 := by
  simp only [BitVec.truncate_eq_setWidth]
  exact BitVec.setWidth_add a b (by decide)

theorem trunc_zext (a : BitVec 32) : ((a.zeroExtend 64).truncate 32) = a := by
  apply BitVec.eq_of_toNat_eq
  have h := a.isLt
  rw [BitVec.truncate_eq_setWidth, BitVec.zeroExtend_eq_setWidth,
    BitVec.toNat_setWidth, BitVec.toNat_setWidth]
  omega

theorem trunc_signExtend (d : BitVec 32) :
    (d.signExtend 64).truncate 32 = d := by
  apply BitVec.eq_of_toNat_eq
  have h := d.isLt
  rw [BitVec.truncate_eq_setWidth, BitVec.toNat_setWidth, BitVec.toNat_signExtend,
    BitVec.toNat_setWidth]
  split <;> omega

/-! ### 1. Zero idiom -/

/-- `xor %r32, %r32` leaves exactly zero in the full 64-bit register. -/
theorem zeroIdiom (r : BitVec 64) :
    ((r.truncate 32 ^^^ r.truncate 32).zeroExtend 64) = (0 : BitVec 64) := by
  simp

/-- `mov $0, %r` (any width) and `xor %r32, %r32` agree on every register;
    they differ only in FLAGS (`fx` is whatever `xor` leaves there). -/
theorem zeroIdiom_state (s : St F) (d : Nat) (fx : F) :
    (St.mk (wr32 s.regs d ((s.regs d).truncate 32 ^^^ (s.regs d).truncate 32)) fx).regs =
      (St.mk (wr s.regs d 0) s.flags).regs := by
  funext x
  simp [wr32, wr]

/-! ### 2. Three-address add as lea -/

/-- 64-bit `lea (a,v)` computes the same sum as `add`. -/
theorem leaQ (a b : BitVec 64) :
    (a+b : BitVec 64) = BitVec.ofNat 64 (a.toNat+b.toNat) := by
  apply BitVec.eq_of_toNat_eq
  simp

/-- 32-bit `lea` truncates the 64-bit address sum; this equals the 32-bit
    `add` of the truncated operands, both zero-extended into the register. -/
theorem leaW (a b : BitVec 64) :
    ((a+b).truncate 32).zeroExtend 64 =
      ((a.truncate 32) + (b.truncate 32)).zeroExtend 64 := by
  rw [trunc_add]

/-- 32-bit `lea disp32(a)` with a sign-extended displacement equals the
    32-bit `add` of the immediate's low 32 bits (`(int32_t)(uint32_t)c`). -/
theorem leaDisp (a : BitVec 64) (d : BitVec 32) :
    ((a + d.signExtend 64).truncate 32) = a.truncate 32 + d := by
  rw [trunc_add, trunc_signExtend]

/-- Kl: `mov a, to; add v, to` vs `lea (a,v), to`, with `to ∉ {a, v}`.
    Registers agree; FLAGS are the only difference. -/
theorem leaQ_state (s : St F) (to a v : Nat) (hv : v ≠ to) (fadd : F) :
    (St.mk (wr (wr s.regs to (s.regs a)) to
        (wr s.regs to (s.regs a) to + wr s.regs to (s.regs a) v)) fadd).regs =
      (St.mk (wr s.regs to (s.regs a + s.regs v)) s.flags).regs := by
  funext x
  by_cases h : x = to <;> simp [wr, hv, h]

/-- Kw: `movl a, to; addl v, to` vs `leal (a,v), to`, with `v ≠ to`. -/
theorem leaW_state (s : St F) (to a v : Nat) (hv : v ≠ to) (fadd : F) :
    let r1 := wr32 s.regs to ((s.regs a).truncate 32)
    (St.mk (wr32 r1 to ((r1 to).truncate 32 + (r1 v).truncate 32)) fadd).regs =
      (St.mk (wr32 s.regs to ((s.regs a + s.regs v).truncate 32)) s.flags).regs := by
  intro r1
  funext x
  by_cases h : x = to
  · subst h
    simp only [r1, wr32, wr, hv, ite_true, ite_false, trunc_add, trunc_zext]
  · simp [r1, wr32, wr, h]

end PionQbeX86ZeroLea
