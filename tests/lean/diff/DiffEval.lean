/-
Lean side of the differential gate (`scripts/test-lean.sh`): prints one
`name: OK <value>` / `name: TRAP` line per case, compared with `native_runner`.
A non-terminating or missing case is a gate failure.
-/
import DiffCases.Funs
open Aeneas Aeneas.Std Result

namespace PionDiff

def report (cn : String) (r : Result Std.I64) : IO Unit :=
  match r.match with
  | .ok v => IO.println s!"{cn}: OK {v.val}"
  | .vis (.fail _) _ => IO.println s!"{cn}: TRAP"
  | .div => throw (IO.userError s!"{cn}: DIVERGED")

def main : IO Unit := do
  report "wrap_add_max" diff_cases.c_wrap_add_max
  report "wrap_sub_min" diff_cases.c_wrap_sub_min
  report "wrap_mul_max" diff_cases.c_wrap_mul_max
  report "abs_min" diff_cases.c_abs_min
  report "neg_min" diff_cases.c_neg_min
  report "abs_neg" diff_cases.c_abs_neg
  report "l_wrap_add" diff_cases.c_l_wrap_add
  report "l_wrap_sub" diff_cases.c_l_wrap_sub
  report "l_wrap_mul" diff_cases.c_l_wrap_mul
  report "l_abs_min" diff_cases.c_l_abs_min
  report "l_neg_min" diff_cases.c_l_neg_min
  report "u_wrap_add" diff_cases.c_u_wrap_add
  report "u_wrap_sub" diff_cases.c_u_wrap_sub
  report "u_wrap_mul" diff_cases.c_u_wrap_mul
  report "ul_wrap_add" diff_cases.c_ul_wrap_add
  report "ul_wrap_sub" diff_cases.c_ul_wrap_sub
  report "ul_wrap_mul" diff_cases.c_ul_wrap_mul
  report "i_bits" diff_cases.c_i_bits
  report "l_bits" diff_cases.c_l_bits
  report "u_bits" diff_cases.c_u_bits
  report "ul_bits" diff_cases.c_ul_bits
  report "div_trunc" diff_cases.c_div_trunc
  report "rem_trunc" diff_cases.c_rem_trunc
  report "l_div_trunc" diff_cases.c_l_div_trunc
  report "l_rem_trunc" diff_cases.c_l_rem_trunc
  report "u_div_big" diff_cases.c_u_div_big
  report "ul_rem_big" diff_cases.c_ul_rem_big
  report "shl_31" diff_cases.c_shl_31
  report "shr_arith" diff_cases.c_shr_arith
  report "l_shl_63" diff_cases.c_l_shl_63
  report "l_shr_arith" diff_cases.c_l_shr_arith
  report "u_shr_logic" diff_cases.c_u_shr_logic
  report "ul_shr_logic" diff_cases.c_ul_shr_logic
  report "ul_shl_int" diff_cases.c_ul_shl_int
  report "ul_shr_int" diff_cases.c_ul_shr_int
  report "u_shl_int" diff_cases.c_u_shl_int
  report "u_shr_int" diff_cases.c_u_shr_int
  report "l_shl_int" diff_cases.c_l_shl_int
  report "l_shr_int" diff_cases.c_l_shr_int
  report "div0" diff_cases.c_div0
  report "rem0" diff_cases.c_rem0
  report "div_ovf" diff_cases.c_div_ovf
  report "rem_ovf" diff_cases.c_rem_ovf
  report "l_div0" diff_cases.c_l_div0
  report "l_rem0" diff_cases.c_l_rem0
  report "l_div_ovf" diff_cases.c_l_div_ovf
  report "l_rem_ovf" diff_cases.c_l_rem_ovf
  report "u_div0" diff_cases.c_u_div0
  report "u_rem0" diff_cases.c_u_rem0
  report "ul_div0" diff_cases.c_ul_div0
  report "ul_rem0" diff_cases.c_ul_rem0
  report "shl_neg" diff_cases.c_shl_neg
  report "shl_32" diff_cases.c_shl_32
  report "shr_32" diff_cases.c_shr_32
  report "l_shl_64" diff_cases.c_l_shl_64
  report "l_shr_64" diff_cases.c_l_shr_64
  report "l_shl_neg" diff_cases.c_l_shl_neg
  report "l_shl_2p32" diff_cases.c_l_shl_2p32
  report "l_shr_2p32" diff_cases.c_l_shr_2p32
  report "ul_shl_64" diff_cases.c_ul_shl_64
  report "ul_shr_64" diff_cases.c_ul_shr_64
  report "ul_shl_2p32" diff_cases.c_ul_shl_2p32
  report "ul_shl_int_64" diff_cases.c_ul_shl_int_64
  report "ul_shl_int_neg" diff_cases.c_ul_shl_int_neg
  report "ul_shr_int_neg" diff_cases.c_ul_shr_int_neg
  report "u_shl_32" diff_cases.c_u_shl_32
  report "u_shl_int_32" diff_cases.c_u_shl_int_32
  report "u_shr_int_neg" diff_cases.c_u_shr_int_neg
  report "l_shl_int_64" diff_cases.c_l_shl_int_64
  report "l_shr_int_neg" diff_cases.c_l_shr_int_neg
  report "arr_get_ok" diff_cases.c_arr_get_ok
  report "arr_get_neg" diff_cases.c_arr_get_neg
  report "arr_get_len" diff_cases.c_arr_get_len
  report "arr_set_ok" diff_cases.c_arr_set_ok
  report "arr_set_neg" diff_cases.c_arr_set_neg
  report "arr_set_len" diff_cases.c_arr_set_len
  report "fa_get_neg" diff_cases.c_fa_get_neg
  report "fa_get_len" diff_cases.c_fa_get_len
  report "fa_set_len" diff_cases.c_fa_set_len
  report "fa_set_ok" diff_cases.c_fa_set_ok
  report "bytes_get_ok" diff_cases.c_bytes_get_ok
  report "bytes_get_neg" diff_cases.c_bytes_get_neg
  report "bytes_get_len" diff_cases.c_bytes_get_len
  report "bytes_set_len" diff_cases.c_bytes_set_len
  report "bytes_set_ok" diff_cases.c_bytes_set_ok
  report "swap_ok" diff_cases.c_swap_ok
  report "swap_same" diff_cases.c_swap_same
  report "swap_oob_i" diff_cases.c_swap_oob_i
  report "swap_oob_j" diff_cases.c_swap_oob_j
  report "pop_empty" diff_cases.c_pop_empty
  report "pop_some" diff_cases.c_pop_some
  report "make_neg" diff_cases.c_make_neg
  report "make_ok" diff_cases.c_make_ok
  report "incl_to_max" diff_cases.c_incl_to_max
  report "incl_empty" diff_cases.c_incl_empty
  report "incl_single" diff_cases.c_incl_single
  report "incl_min" diff_cases.c_incl_min
  report "nest_plain" diff_cases.c_nest_plain
  report "nest_break0" diff_cases.c_nest_break0
  report "nest_return" diff_cases.c_nest_return
  report "guard_ok" diff_cases.c_guard_ok
  report "guard_err" diff_cases.c_guard_err
  report "chain_ok" diff_cases.c_chain_ok
  report "chain_err1" diff_cases.c_chain_err1
  report "chain_err2" diff_cases.c_chain_err2
  report "chain_trap" diff_cases.c_chain_trap
  report "codec_pack_max" diff_cases.c_codec_pack_max
  report "codec_pack_mid" diff_cases.c_codec_pack_mid
  report "codec_rej_tag" diff_cases.c_codec_rej_tag
  report "codec_rej_rights" diff_cases.c_codec_rej_rights
  report "codec_rej_badge" diff_cases.c_codec_rej_badge
  report "codec_rej_pfn" diff_cases.c_codec_rej_pfn
  report "codec_unpack" diff_cases.c_codec_unpack
  report "codec_unpack_max" diff_cases.c_codec_unpack_max
  report "codec_restrict" diff_cases.c_codec_restrict
  report "codec_restrict_zero" diff_cases.c_codec_restrict_zero
  report "codec_restrict_all" diff_cases.c_codec_restrict_all
  report "bs_hit" diff_cases.c_bs_hit
  report "bs_miss" diff_cases.c_bs_miss
  report "bs_empty" diff_cases.c_bs_empty
  report "bs_first" diff_cases.c_bs_first
  report "bs_extremes" diff_cases.c_bs_extremes
  report "sort_mixed" diff_cases.c_sort_mixed
  report "sort_empty" diff_cases.c_sort_empty
  report "sort_rev" diff_cases.c_sort_rev
  report "cap_create" diff_cases.c_cap_create
  report "cap_create_neg" diff_cases.c_cap_create_neg
  report "cap_insert" diff_cases.c_cap_insert
  report "cap_insert_oob" diff_cases.c_cap_insert_oob
  report "cap_insert_null" diff_cases.c_cap_insert_null
  report "cap_insert_busy" diff_cases.c_cap_insert_busy
  report "cap_copy" diff_cases.c_cap_copy
  report "cap_copy_empty" diff_cases.c_cap_copy_empty
  report "cap_mint" diff_cases.c_cap_mint
  report "cap_mint_wrong" diff_cases.c_cap_mint_wrong
  report "cap_delete" diff_cases.c_cap_delete
  report "cap_delete_empty" diff_cases.c_cap_delete_empty
  report "cap_revoke" diff_cases.c_cap_revoke
  report "sb_basic" diff_cases.c_sb_basic
  report "map_str" diff_cases.c_map_str
  report "map_int" diff_cases.c_map_int
  report "double_bits" diff_cases.c_double_bits
  report "match_unit_enum" diff_cases.c_match_unit_enum
  report "match_guarded_enum" diff_cases.c_match_guarded_enum
  report "match_single_ctor_guard" diff_cases.c_match_single_ctor_guard
  report "match_const_pat" diff_cases.c_match_const_pat
  report "match_wild_tail" diff_cases.c_match_wild_tail
  report "match_is_single_ctor" diff_cases.c_match_is_single_ctor
  report "match_peeled_dead_arm" diff_cases.c_match_peeled_dead_arm

end PionDiff

#eval PionDiff.main
