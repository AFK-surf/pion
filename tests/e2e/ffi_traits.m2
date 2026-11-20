extern "C" fn c_strlen(s : Ptr) -> Int64 = "strlen"
extern "C" fn c_abs(x : Int) -> Int = "abs"
extern "C" fn c_malloc(n : Int64) -> Ptr = "malloc"
extern "C" fn c_free(p : Ptr) -> Unit = "free"

pub trait Show {
  show(self : Self) -> String
}

pub trait Hash {
  hash(self : Self) -> Int
}

pub struct User {
  id : Int
  name : String
}

impl Show for Int {
  fn show(self : Int) -> String {
    self.to_string()
  }
}

impl Hash for Int {
  fn hash(self : Int) -> Int {
    self * 31 + 7
  }
}

impl Show for String {
  fn show(self : String) -> String {
    self
  }
}

impl Hash for String {
  fn hash(self : String) -> Int {
    let mut h = 5381
    let mut i = 0
    while i < self.length() {
      h = h * 33 + self.code_unit_at(i)
      i = i + 1
    }
    h
  }
}

impl Show for User {
  fn show(self : User) -> String {
    "User(\{self.id}, \{self.name})"
  }
}

impl Hash for User {
  fn hash(self : User) -> Int {
    self.id * 131 + self.name.length()
  }
}

fn format_pair[A : Show, B : Show](a : A, b : B) -> String {
  a.show() + ":" + b.show()
}

fn hash_and_show[T : Show + Hash](x : T) -> String {
  x.show() + "#" + x.hash().to_string()
}

pub fn main(world : World) -> Int {
  // 1. extern "C" FFI + Ptr helpers
  let nil = ptr_null()
  if !ptr_is_null(nil) {
    return 1
  }
  if ptr_addr(nil) != 0L {
    return 2
  }
  let greeting = "hello, m2 ffi!"
  let clen = c_strlen(greeting.as_cstr())
  if clen != 14L {
    return 3
  }
  if c_abs(-42) != 42 {
    return 4
  }
  let buf = c_malloc(64L)
  if ptr_is_null(buf) {
    return 5
  }
  if ptr_addr(buf) == 0L {
    c_free(buf)
    return 6
  }
  c_free(buf)

  // 2. First-class trait / impl + zero-overhead monomorphization
  let u = User::{ id: 7, name: "ada" }
  let pair = format_pair(42, u)
  let hs_int = hash_and_show(10)
  let hs_str = hash_and_show("m2")
  let hs_usr = hash_and_show(u)
  let direct = u.show()

  if pair != "42:User(7, ada)" {
    return 7
  }
  if hs_int != "10#317" {
    return 8
  }
  if direct != "User(7, ada)" {
    return 9
  }
  if hs_usr != "User(7, ada)#920" {
    return 10
  }

  io_println(world, "ffi_len=" + clen.to_string() + " abs=" + c_abs(-42).to_string())
  io_println(world, "pair=" + pair + " hs_int=" + hs_int + " hs_str=" + hs_str + " hs_usr=" + hs_usr)
  0
}
