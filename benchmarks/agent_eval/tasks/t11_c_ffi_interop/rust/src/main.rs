//! t11_c_ffi_interop: libc + zlib through `extern "C"`
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_uint, c_ulong};

extern "C" {
    fn strlen(s: *const c_char) -> usize;
    fn abs(x: c_int) -> c_int;
}

#[link(name = "z")]
extern "C" {
    fn crc32(crc: c_ulong, buf: *const u8, len: c_uint) -> c_ulong;
    fn zlibVersion() -> *const c_char;
}

pub const FOX: &str = "The quick brown fox jumps over the lazy dog";

pub fn c_strlen(s: &str) -> usize {
    let c = CString::new(s).expect("no interior NUL");
    // SAFETY: `c` is a valid NUL-terminated string for the duration of the call.
    unsafe { strlen(c.as_ptr()) }
}

pub fn c_abs(x: i32) -> i32 {
    // SAFETY: `abs` has no preconditions besides x != INT_MIN.
    unsafe { abs(x) }
}

pub fn crc32_of(s: &str) -> u64 {
    // SAFETY: pointer/length describe the live byte slice of `s`.
    unsafe { crc32(0, s.as_ptr(), s.len() as c_uint) as u64 }
}

pub fn zlib_major() -> String {
    // SAFETY: zlibVersion returns a static NUL-terminated string.
    let v = unsafe { CStr::from_ptr(zlibVersion()) }.to_string_lossy().into_owned();
    v.split('.').next().unwrap_or("").to_string()
}

fn main() {
    println!("strlen(\"hello, agent\")={}", c_strlen("hello, agent"));
    println!("abs(-42)={}", c_abs(-42));
    println!("crc32(\"{}\")={:08x}", FOX, crc32_of(FOX));
    println!("zlib_major={}", zlib_major());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi() {
        assert_eq!(c_strlen(""), 0);
        assert_eq!((c_abs(7), c_abs(-2147483647)), (7, 2147483647));
        assert_eq!(crc32_of(""), 0);
        assert_eq!(format!("{:08x}", crc32_of(FOX)), "414fa339");
        assert_eq!(format!("{:08x}", 255), "000000ff");
    }
}
