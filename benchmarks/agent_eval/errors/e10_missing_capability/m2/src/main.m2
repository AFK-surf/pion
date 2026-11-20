/// A "pure" helper that quietly does file IO.
fn load_config(path : String) -> String {
  match fs_read(path) {
    Ok(s) => s
    Err(_) => ""
  }
}

pub fn main(world : World) -> Int {
  io_println(world, load_config("/etc/hosts"))
  0
}
