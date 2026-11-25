# The same private literal also loaded through the GOT (`extern`,
# R_X86_64_GOTPCREL): the symbol keeps its name, so a partial link that moves
# the literal still resolves to its address.
data $pion_cstr_0 = align 8 { b "got literal", b 0 }
export function l $lit_got() {
@start
	%p =l copy extern $pion_cstr_0
	ret %p
}
export function l $lit_got_direct() {
@start
	ret $pion_cstr_0
}
