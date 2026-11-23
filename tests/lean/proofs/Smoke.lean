/-
Smoke proofs over extracted code with Aeneas' `step` (the successor of
`progress`) and `scalar_tac`; every goal is closed.
-/
import Algos.Funs
open Aeneas Aeneas.Std Result Pion WP

namespace PionProofs

/-- `swap(mut a, mut b)` returns the swapped pair. -/
theorem swap_spec (a b : Std.I32) : algos.swap a b ⦃ r => r = (b, a) ⦄ := by
  unfold algos.swap
  simp

/-- `avg2` never fails and divides the (wrapping) sum by two. -/
theorem avg2_spec (a b : Std.I32) :
    algos.avg2 a b ⦃ r => r.val = Int.tdiv (Pion.I32.add a b).val 2 ⦄ := by
  unfold algos.avg2
  step as ⟨ t, ht ⟩
  simp [ht]

/-- `safe_div` fails exactly on a zero divisor / overflow; otherwise it is `/`. -/
theorem safe_div_spec (a b : Std.I32) (hb : b.val ≠ 0) (hov : ¬ (a.val = -2147483648 ∧ b.val = -1)) :
    vlib.safe_div a b ⦃ r => r.val = Int.tdiv a.val b.val ⦄ := by
  unfold vlib.safe_div
  step as ⟨ t, ht ⟩
  simp [ht]

/-- `move_rect` moves both `x` coordinates by `dx` and swaps the `y` ones. -/
theorem move_rect_spec (r : algos.Rect) (dx : Std.I32) :
    algos.move_rect r dx ⦃ r' => r'.lo.x = Pion.I32.add r.lo.x dx ∧ r'.hi.x = Pion.I32.add r.hi.x dx ∧
      r'.lo.y = r.hi.y ∧ r'.hi.y = r.lo.y ⦄ := by
  unfold algos.move_rect algos.swap
  simp

/-- `StringBuilder` write_string roundtrips through `to_string`. -/
theorem sb_write_string_roundtrip (s : String) :
    (Pion.StringBuilder.new.write_string s).to_string = s :=
  Pion.StringBuilder.to_string_write_string s

/-- `Map` set/get/remove laws compose cleanly. -/
theorem map_set_remove_law (m : Pion.Map String Std.I32) (v1 v2 : Std.I32) :
    (((m.set "a" v1).set "b" v2).remove "a").get "b" = some v2 ∧
    (((m.set "a" v1).set "b" v2).remove "a").get "a" = none := by
  constructor
  · rw [Pion.Map.get_remove_ne _ (by decide), Pion.Map.get_set_eq]
  · exact Pion.Map.get_remove_eq _ _

/-- `Double` bit-pattern roundtrip preserves all 64 bits. -/
theorem double_bits_roundtrip (b : Std.I64) :
    (Pion.Double.from_bits b).to_bits = b :=
  Pion.Double.to_bits_from_bits b

end PionProofs
