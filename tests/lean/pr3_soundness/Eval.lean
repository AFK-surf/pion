import Pr3Soundness.Funs
open Aeneas Aeneas.Std Result

namespace Pr3Eval

def report (cn : String) (r : Result Std.I32) : IO Unit :=
  match r.match with
  | .ok v => IO.println s!"{cn}: OK {v.val}"
  | .vis (.fail _) _ => IO.println s!"{cn}: TRAP"
  | .div => throw (IO.userError s!"{cn}: DIVERGED")

def main : IO Unit := do
  report "c_01_field_compound_assign" pr3_soundness.c_01_field_compound_assign
  report "c_02_string_index" pr3_soundness.c_02_string_index
  report "c_02_string_index_oob" pr3_soundness.c_02_string_index_oob
  report "c_03_into_call_arg" pr3_soundness.c_03_into_call_arg
  report "c_04_try_into_err" pr3_soundness.c_04_try_into_err
  report "c_05_keyword_and_collision" pr3_soundness.c_05_keyword_and_collision
  report "c_06_retarget_mut_assign" pr3_soundness.c_06_retarget_mut_assign
  report "c_07_range_start_snapshot" pr3_soundness.c_07_range_start_snapshot
  report "c_08_struct_update_base" pr3_soundness.c_08_struct_update_base
  report "c_09_for_continue_shadow" pr3_soundness.c_09_for_continue_shadow
  report "c_10_match_lit_guard_skip" pr3_soundness.c_10_match_lit_guard_skip
  report "c_11_match_scrut_snapshot" pr3_soundness.c_11_match_scrut_snapshot
  report "c_12_sb_write_effect" pr3_soundness.c_12_sb_write_effect
  report "c_13_named_arg_eval_order" pr3_soundness.c_13_named_arg_eval_order
  report "c_14_cross_pkg_default_param" pr3_soundness.c_14_cross_pkg_default_param
  report "c_15_param_shadow_pkg_fn" pr3_soundness.c_15_param_shadow_pkg_fn
  report "c_16_loop_helper_collision" pr3_soundness.c_16_loop_helper_collision
  report "c_17_lean4_keywords" pr3_soundness.c_17_lean4_keywords
  report "c_18_map_non_literal" pr3_soundness.c_18_map_non_literal
  report "c_19_cross_pkg_generic_default" pr3_soundness.c_19_cross_pkg_generic_default
  report "c_20_default_ref_prior_param" pr3_soundness.c_20_default_ref_prior_param
  report "c_21_loop_helper_param_shadow" pr3_soundness.c_21_loop_helper_param_shadow
  report "c_22_generic_local_map_eq" pr3_soundness.c_22_generic_local_map_eq
  report "c_23_more_lean_keywords" pr3_soundness.c_23_more_lean_keywords
  report "c_24_for_cond_is_no_leak" pr3_soundness.c_24_for_cond_is_no_leak
  report "l_25_opt_param_default_ref" pr3_soundness.l_25_opt_param_default_ref
  report "l_26_generic_map_eq_transitive" pr3_soundness.l_26_generic_map_eq_transitive
  report "l_27_loop_helper_tparam_shadow" pr3_soundness.l_27_loop_helper_tparam_shadow
  report "l_28_nested_loop_helper_tparam_shadow" pr3_soundness.l_28_nested_loop_helper_tparam_shadow
  report "l_29_generic_map_product_key_eq" pr3_soundness.l_29_generic_map_product_key_eq

end Pr3Eval

#eval Pr3Eval.main
