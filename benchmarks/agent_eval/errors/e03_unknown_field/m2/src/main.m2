pub struct User {
  name : String
  age : Int
}

pub fn main(world : World) -> Int {
  let u = User::{ name: "ada", age: 36 }
  io_println(world, u.agee.to_string())
  0
}
