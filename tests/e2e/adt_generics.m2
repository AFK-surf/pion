///| Comprehensive ADT, generics, mut struct, containers, closures, and 32-bit Int test

pub enum Expr {
  Lit(Int)
  Add(Expr, Expr)
  Mul(Expr, Expr)
}

pub fn eval(e : Expr) -> Int {
  match e {
    Lit(n) => n
    Add(a, b) => eval(a) + eval(b)
    Mul(a, b) => eval(a) * eval(b)
  }
}

pub struct Box[T] {
  mut value : T
}

pub fn Box::get[T](self : Box[T]) -> T {
  self.value
}

pub fn Box::set[T](self : Box[T], v : T) -> Unit {
  self.value = v
}

pub fn apply(f : (Int) -> Int, x : Int) -> Int {
  f(x)
}

pub fn main(world : World) -> Int {
  // 1. Recursive enum + exhaustive match: (3 + 4) * (2 + 5) = 49
  let ast = Mul(Add(Lit(3), Lit(4)), Add(Lit(2), Lit(5)))
  let v_ast = eval(ast)

  // 2. Generic struct with mut field + methods (Int and String instantiations)
  let bi : Box[Int] = Box::{ value: 10 }
  bi.set(bi.get() + 32)
  let bs : Box[String] = Box::{ value: "init" }
  bs.set("boxed:" + bi.get().to_string())

  // 3. Array operations
  let arr : Array[Int] = [1, 2, 3]
  arr.push(4)
  arr[1] = 20
  let arr_cp = arr.copy()
  arr_cp.push(99)
  let popped = match arr.pop() {
    Some(x) => x
    None => -1
  }
  let arr_sum = arr[0] + arr[1] + arr[2] + popped

  // 4. Map operations (set, get, contains, remove, copy, length)
  let m : Map[String, Int] = Map::new()
  m.set("alpha", 100)
  m.set("beta", 200)
  m.set("gamma", 300)
  let m_cp = m.copy()
  m.remove("beta")
  let has_beta = m.contains("beta")
  let cp_beta = match m_cp.get("beta") {
    Some(v) => v
    None => -1
  }
  let alpha_v = match m.get("alpha") {
    Some(v) => v
    None => -1
  }

  // 5. StringBuilder (write_string, write_char, reset, to_string)
  let sb = StringBuilder()
  sb.write_string("discard")
  sb.reset()
  sb.write_string("m2")
  sb.write_char('-')
  sb.write_string("ok")
  let built = sb.to_string()

  // 6. Closure capturing local variable + higher-order function
  let factor = 7
  let mul_factor = fn(x : Int) -> Int { x * factor + 1 }
  let clo_res = apply(mul_factor, 6)

  // 7. Exact 32-bit Int wraparound semantics
  let max32 = 2147483647
  let wrapped = max32 + 1
  let is_min32 = wrapped == -2147483647 - 1

  io_println(world, "ast=" + v_ast.to_string())
  io_println(world, "box=" + bs.get())
  io_println(
    world,
    "arr=" +
    arr_sum.to_string() +
    ",len=" +
    arr.length().to_string() +
    ",cplen=" +
    arr_cp.length().to_string(),
  )
  io_println(
    world,
    "map=" +
    alpha_v.to_string() +
    ",has_beta=" +
    has_beta.to_string() +
    ",cp_beta=" +
    cp_beta.to_string() +
    ",len=" +
    m.length().to_string(),
  )
  io_println(world, "sb=" + built)
  io_println(world, "clo=" + clo_res.to_string())
  io_println(world, "i32wrap=" + is_min32.to_string())
  0
}
