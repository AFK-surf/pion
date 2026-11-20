# t11_c_ffi_interop — calling C libraries (libc + zlib)

Call four C functions directly from each language and link `libz`:

- `strlen("hello, agent")` (libc, NUL-terminated string argument)
- `abs(-42)` (libc)
- `crc32(0, "The quick brown fox jumps over the lazy dog", 43)` (zlib; buffer pointer + length, 64-bit `uLong` result)
- `zlibVersion()` (zlib; returns `const char*` that must be turned back into a string; print its major version)

Language mechanisms: Pion `extern "C" fn ... = "sym"` + `[link] libs = ["z"]` in `pion.toml`;
Rust `extern "C"` block with `#[link(name = "z")]` + `unsafe` calls; Go `cgo` (`import "C"`, `#cgo LDFLAGS: -lz`);
MoonBit native `extern "C" fn` + `cc-link-flags`, plus a tiny C stub to copy `zlibVersion()`'s `char*` into
MoonBit `Bytes` (MoonBit cannot read a raw C string directly).

`main` prints `strlen(...)=12`, `abs(-42)=42`, `crc32(...)=414fa339` (8 lowercase hex digits) and `zlib_major=1`.
