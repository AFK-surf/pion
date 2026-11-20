fn save(x : Int) -> Result[Unit, String] {
  if x < 0 {
    Err("negative")
  } else {
    Ok(())
  }
}

pub fn main(world : World) -> Int {
  save(-1)
  io_println(world, "saved")
  0
}
