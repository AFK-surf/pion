// t11_c_ffi_interop: libc + zlib through cgo
package main

/*
#cgo LDFLAGS: -lz
#include <stdlib.h>
#include <string.h>
#include <zlib.h>
*/
import "C"

import (
	"fmt"
	"strings"
	"unsafe"
)

const Fox = "The quick brown fox jumps over the lazy dog"

func CStrlen(s string) int {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return int(C.strlen(cs))
}

func CAbs(x int) int { return int(C.abs(C.int(x))) }

func Crc32Of(s string) uint64 {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return uint64(C.crc32(0, (*C.Bytef)(unsafe.Pointer(cs)), C.uInt(len(s))))
}

func ZlibMajor() string {
	v := C.GoString(C.zlibVersion())
	major, _, _ := strings.Cut(v, ".")
	return major
}

func main() {
	fmt.Printf("strlen(\"hello, agent\")=%d\n", CStrlen("hello, agent"))
	fmt.Printf("abs(-42)=%d\n", CAbs(-42))
	fmt.Printf("crc32(\"%s\")=%08x\n", Fox, Crc32Of(Fox))
	fmt.Printf("zlib_major=%s\n", ZlibMajor())
}
