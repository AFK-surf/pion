/-
Axiom gate (`scripts/test-lean.sh`): every theorem below may depend only on
`propext`, `Classical.choice` and `Quot.sound`.
-/
import PionProofs.Smoke
import PionProofs.CodecProofs
import PionProofs.AlgosProofs
import PionProofs.CapTableProofs

#print axioms PionProofs.CodecP.pack_unpack_roundtrip
#print axioms PionProofs.CodecP.pack_rejects_invalid
#print axioms PionProofs.CodecP.restrict_rights_preserves_other_fields
#print axioms PionProofs.AlgosP.binary_search_sound
#print axioms PionProofs.AlgosP.binary_search_complete
#print axioms PionProofs.AlgosP.insertion_sort_spec
#print axioms PionProofs.CapTableP.create_inv
#print axioms PionProofs.CapTableP.insert_preserves_inv
#print axioms PionProofs.CapTableP.copy_cap_preserves_inv
#print axioms PionProofs.CapTableP.mint_preserves_inv
#print axioms PionProofs.CapTableP.delete_preserves_inv
#print axioms PionProofs.CapTableP.revoke_badge_preserves_inv
#print axioms PionProofs.CapTableP.insert_frame
#print axioms PionProofs.CapTableP.copy_cap_frame
#print axioms PionProofs.CapTableP.mint_frame
#print axioms PionProofs.CapTableP.delete_frame
#print axioms PionProofs.CapTableP.mint_rights_monotone
#print axioms PionProofs.CapTableP.revoke_badge_complete
#print axioms PionProofs.swap_spec
#print axioms PionProofs.avg2_spec
#print axioms PionProofs.safe_div_spec
#print axioms PionProofs.move_rect_spec
#print axioms PionProofs.sb_write_string_roundtrip
#print axioms PionProofs.map_set_remove_law
#print axioms PionProofs.double_bits_roundtrip
