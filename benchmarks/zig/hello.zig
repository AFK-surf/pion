extern "c" fn puts(s: [*:0]const u8) c_int;

pub fn main() void {
    _ = puts("hello m2");
}
