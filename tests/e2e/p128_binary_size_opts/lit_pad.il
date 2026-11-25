# Placed first by `ld -r`, so the literals of the other objects move to a
# non-zero offset of the merged `.data.pion_cstr_0`.
data $pion_cstr_0 = align 8 { b "padding literal of 31 bytes...", b 0 }
export function l $lit_pad() {
@start
	ret $pion_cstr_0
}
