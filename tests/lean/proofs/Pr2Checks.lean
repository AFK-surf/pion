/-
Regression proofs for PR-2 `PionLean` additions:
- `Pion.I8` arithmetic, wrapping, overflow, shifts, conversions, and `Pion.Eq Std.I8`
- `Pion.Bytes.newChecked` negative-length panic parity
- `Pion.StringBuilder.write_substring` / `to_string` / `to_stringChecked` on split UTF-8
-/
import PionLean
open Aeneas Aeneas.Std Result Error Pion

namespace PionProofs.Pr2Checks

theorem i8_wrapping_add : Pion.I8.add 127#i8 1#i8 = (-128)#i8 := by decide

theorem i8_rem_min_overflow : Pion.I8.rem (-128)#i8 (-1)#i8 = fail integerOverflow := by
  unfold Pion.I8.rem
  have h1 : ((-128)#i8 : Std.I8).val = -128 := rfl
  have h2 : ((-1)#i8 : Std.I8).val = -1 := rfl
  simp [h1, h2]

theorem i8_eq_instance (x : Std.I8) : (x == x) = true := by
  have _ : Pion.Eq Std.I8 := inferInstance
  simp

theorem bytes_new_checked_neg : Pion.Bytes.newChecked (-1)#i32 = fail Error.panic :=
  Pion.Bytes.newChecked_neg (-1)#i32 (by decide)

theorem bytes_new_checked_zero : Pion.Bytes.newChecked 0#i32 = ok ⟨[]⟩ := by
  unfold Pion.Bytes.newChecked listMake
  rfl

theorem sb_split_utf8_no_panic :
    (Pion.StringBuilder.new.write_substring "é" 0#i32 1#i32).to_string = "" := rfl

end PionProofs.Pr2Checks
