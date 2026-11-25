# A private literal reached only by S + A relocations (PC32 lea, R_X86_64_64
# in data): it is referenced through its section symbol.
data $pion_cstr_0 = align 8 { b "direct literal", b 0 }
export data $lit_direct_ptr = align 8 { l $pion_cstr_0 }
export function l $lit_direct() {
@start
	ret $pion_cstr_0
}
