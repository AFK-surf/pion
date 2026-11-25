/-
Soundness of the `amd64_sysv` release guarded integer-array exchange
(`qbe_emit_guarded_exchange` in `compiler/src/core/qbe.pion`, regression test
`tests/e2e/p123_amd64_guarded_exchange`).

Inside the fast path of `qbe_try_emit_while_bce_versioned`, the loop

    while i < bound {
      let tmp = a[i]
      a[i] = a[axis - i]
      a[axis - i] = tmp
      i = i + 1
    }

over a native `Array[Int]` (4-byte elements at data pointer `base`) becomes

    left  = base + 4*start,  right = base + 4*(axis - start)
    stop  = base + 4*bound
    loop: x = [left]; y = [right]; [left] = y; [right] = x
          left += 4; right -= 4; if left != stop goto loop
    i = bound

The fast path is only reached when `start < bound` (entry check) and the
64-bit pre-loop guard holds: `0 <= start`, `bound <= len` (left side, guard
kind 0) and `0 <= axis - bound + 1`, `axis - start < len` (right side, guard
kind 2); `start`, `bound`, `axis` are signed 32-bit values.

  1. `sameTrace`: the pointer loop and the indexed loop call any stateful
     ordered exchange `swap` (modelling memory and an access trace) on the
     same address pairs in the same order, including coinciding addresses.
  2. `fastBounds`: every iteration's two indices are in `[0, len)`, and the
     32-bit `axis - i` and `i + 1` neither overflow nor underflow.
  3. `noEarlyStop`: comparing the advanced left pointer with the one-past
     sentinel modulo 2^64 holds exactly at the last iteration.
  4. `finalInduction`: after `bound - start` iterations the induction variable
     equals `bound`, the value stored back to its slot.
  5. `emptyNoSwap` / `singleSelfSwap` / `stepCount`: zero iterations leave the
     state unchanged; a one-element range with `axis = 2*start` swaps one
     in-range address with itself; the pointer loop runs exactly
     `bound - start` iterations.
-/
import Std

namespace PionQbeAmd64GuardedExchange

/-- The source loop: `n` exchanges of `a[i]` and `a[axis - i]`, `i` advancing. -/
def indexed {S : Type} (swap : Int → Int → S → S) (base axis : Int) :
    Nat → Int → S → S
  | 0, _, s => s
  | n + 1, i, s =>
    indexed swap base axis n (i + 1) (swap (base + 4 * i) (base + 4 * (axis - i)) s)

/-- The emitted loop: a left pointer advancing and a right pointer retreating by 4. -/
def pointers {S : Type} (swap : Int → Int → S → S) : Nat → Int → Int → S → S
  | 0, _, _, s => s
  | n + 1, l, r, s => pointers swap n (l + 4) (r - 4) (swap l r s)

theorem sameTrace {S : Type} (swap : Int → Int → S → S) (base axis : Int) (n : Nat)
    (i : Int) (s : S) :
    pointers swap n (base + 4 * i) (base + 4 * (axis - i)) s =
      indexed swap base axis n i s := by
  induction n generalizing i s with
  | zero => rfl
  | succ n ih =>
    simp only [pointers, indexed]
    have hL : base + 4 * i + 4 = base + 4 * (i + 1) := by omega
    have hR : base + 4 * (axis - i) - 4 = base + 4 * (axis - (i + 1)) := by omega
    rw [hL, hR]
    apply ih

theorem fastBounds (start bound axis len i : Int)
    (hStart : 0 ≤ start) (hBound : bound ≤ len)
    (hLow : 0 ≤ axis - bound + 1) (hHigh : axis - start < len)
    (hI : start ≤ i) (hEnd : i < bound)
    (hWord : axis ≤ 2147483647) (hBWord : bound ≤ 2147483647) :
    0 ≤ i ∧ i < len ∧ 0 ≤ axis - i ∧ axis - i < len ∧ axis - i ≤ 2147483647 ∧
      i + 1 ≤ 2147483647 := by
  omega

/-- QBE compares machine addresses modulo 2^64. On the signed 32-bit induction
domain the advancing pointer meets the one-past sentinel only at the end. -/
theorem noEarlyStop (base i bound : Int) (hI : 0 ≤ i) (hEnd : i < bound)
    (hBound : bound ≤ 2147483647) :
    (base + 4 * (i + 1)) % 18446744073709551616 =
        (base + 4 * bound) % 18446744073709551616 ↔ i + 1 = bound := by
  constructor
  · intro h
    have h1 := Int.emod_add_mul_ediv (base + 4 * (i + 1)) 18446744073709551616
    have h2 := Int.emod_add_mul_ediv (base + 4 * bound) 18446744073709551616
    omega
  · intro h
    rw [h]

theorem finalInduction (start bound : Int) (enter : start < bound) :
    start + (bound - start).toNat = bound := by
  omega

theorem emptyNoSwap {S : Type} (swap : Int → Int → S → S) (l r : Int) (s : S) :
    pointers swap 0 l r s = s := rfl

theorem singleSelfSwap (start len : Int) (hStart : 0 ≤ start) (hBound : start + 1 ≤ len) :
    2 * start - start = start ∧ 0 ≤ 2 * start - start ∧ 2 * start - start < len ∧
      0 ≤ 2 * start - (start + 1) + 1 := by
  omega

/-- Iteration `k` of the pointer loop stops exactly when `k + 1 = bound - start`. -/
theorem stepCount (base start bound : Int) (k : Nat) (hStart : 0 ≤ start)
    (hK : start + k < bound) (hBound : bound ≤ 2147483647) :
    ((base + 4 * start) + 4 * ((k : Int) + 1)) % 18446744073709551616 =
        (base + 4 * bound) % 18446744073709551616 ↔ (k : Int) + 1 = bound - start := by
  have h := noEarlyStop base (start + k) bound (by omega) hK hBound
  have e : base + 4 * start + 4 * ((k : Int) + 1) = base + 4 * (start + k + 1) := by omega
  rw [e]
  constructor
  · intro hm
    have := h.mp hm
    omega
  · intro hk
    apply h.mpr
    omega

end PionQbeAmd64GuardedExchange
