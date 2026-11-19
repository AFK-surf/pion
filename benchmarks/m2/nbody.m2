///| Benchmarks Game: N-body (N = 5_000_000) in m2
let PI : Double = 3.141592653589793
let SOLAR_MASS : Double = 4.0 * PI * PI
let DAYS_PER_YEAR : Double = 365.24

pub struct Body {
  mut x : Double
  mut y : Double
  mut z : Double
  mut vx : Double
  mut vy : Double
  mut vz : Double
  mass : Double
}

fn sqrt_d(x : Double) -> Double {
  if x <= 0.0 {
    return 0.0
  }
  let mut g = if x > 1.0 { x * 0.5 } else { 1.0 }
  let mut i = 0
  while i < 16 {
    g = 0.5 * (g + x / g)
    i = i + 1
  }
  g
}

fn fmt_fixed9(v : Double) -> String {
  let neg = v < 0.0
  let av = if neg { -v } else { v }
  let scaled = (av * 1000000000.0 + 0.5).to_int()
  let whole = scaled / 1000000000
  let frac = scaled % 1000000000
  let frac_s = frac.to_string()
  let sb = StringBuilder::new()
  if neg && scaled != 0 {
    sb.write_char('-')
  }
  sb.write_string(whole.to_string())
  sb.write_char('.')
  let mut pad = 9 - frac_s.length()
  while pad > 0 {
    sb.write_char('0')
    pad = pad - 1
  }
  sb.write_string(frac_s)
  sb.to_string()
}

fn offset_momentum(bodies : Array[Body]) -> Unit {
  let mut px = 0.0
  let mut py = 0.0
  let mut pz = 0.0
  let mut i = 0
  while i < bodies.length() {
    let b = bodies[i]
    px = px + b.vx * b.mass
    py = py + b.vy * b.mass
    pz = pz + b.vz * b.mass
    i = i + 1
  }
  bodies[0].vx = -px / SOLAR_MASS
  bodies[0].vy = -py / SOLAR_MASS
  bodies[0].vz = -pz / SOLAR_MASS
}

fn energy(bodies : Array[Body]) -> Double {
  let mut e = 0.0
  let n = bodies.length()
  let mut i = 0
  while i < n {
    let b = bodies[i]
    e = e + 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz)
    let mut j = i + 1
    while j < n {
      let b2 = bodies[j]
      let dx = b.x - b2.x
      let dy = b.y - b2.y
      let dz = b.z - b2.z
      let distance = sqrt_d(dx * dx + dy * dy + dz * dz)
      e = e - b.mass * b2.mass / distance
      j = j + 1
    }
    i = i + 1
  }
  e
}

fn advance(bodies : Array[Body], dt : Double) -> Unit {
  let n = bodies.length()
  let mut i = 0
  while i < n {
    let b = bodies[i]
    let mut j = i + 1
    while j < n {
      let b2 = bodies[j]
      let dx = b.x - b2.x
      let dy = b.y - b2.y
      let dz = b.z - b2.z
      let d2 = dx * dx + dy * dy + dz * dz
      let distance = sqrt_d(d2)
      let mag = dt / (d2 * distance)
      b.vx = b.vx - dx * b2.mass * mag
      b.vy = b.vy - dy * b2.mass * mag
      b.vz = b.vz - dz * b2.mass * mag
      b2.vx = b2.vx + dx * b.mass * mag
      b2.vy = b2.vy + dy * b.mass * mag
      b2.vz = b2.vz + dz * b.mass * mag
      j = j + 1
    }
    i = i + 1
  }
  let mut k = 0
  while k < n {
    let b = bodies[k]
    b.x = b.x + dt * b.vx
    b.y = b.y + dt * b.vy
    b.z = b.z + dt * b.vz
    k = k + 1
  }
}

pub fn main(world : World) -> Int {
  let n = 5000000
  let bodies : Array[Body] = [
    Body::{ x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: SOLAR_MASS },
    Body::{
      x: 4.84143144246472090,
      y: -1.16032004402742839,
      z: -0.103622044471123109,
      vx: 0.00166007664274403694 * DAYS_PER_YEAR,
      vy: 0.00769901118419740425 * DAYS_PER_YEAR,
      vz: -0.0000690460016972063023 * DAYS_PER_YEAR,
      mass: 0.000954791938424326609 * SOLAR_MASS,
    },
    Body::{
      x: 8.34336671824457987,
      y: 4.12479856412430479,
      z: -0.403523417114321381,
      vx: -0.00276742510726862411 * DAYS_PER_YEAR,
      vy: 0.00499852801234917238 * DAYS_PER_YEAR,
      vz: 0.0000230417297573763929 * DAYS_PER_YEAR,
      mass: 0.000285885980666130812 * SOLAR_MASS,
    },
    Body::{
      x: 12.8943695621391310,
      y: -15.1111514016986312,
      z: -0.223307578892655734,
      vx: 0.00296460137564761618 * DAYS_PER_YEAR,
      vy: 0.00237847173959480950 * DAYS_PER_YEAR,
      vz: -0.0000296589568540237556 * DAYS_PER_YEAR,
      mass: 0.0000436624404335156298 * SOLAR_MASS,
    },
    Body::{
      x: 15.3796971148509165,
      y: -25.9193146099879641,
      z: 0.179258772950371181,
      vx: 0.00268067772490389322 * DAYS_PER_YEAR,
      vy: 0.00162824170038242295 * DAYS_PER_YEAR,
      vz: -0.0000951592254519715870 * DAYS_PER_YEAR,
      mass: 0.0000515138902046611451 * SOLAR_MASS,
    },
  ]
  offset_momentum(bodies)
  let e0 = energy(bodies)
  let mut i = 0
  while i < n {
    advance(bodies, 0.01)
    i = i + 1
  }
  let e1 = energy(bodies)
  io_println(world, fmt_fixed9(e0) + " " + fmt_fixed9(e1))
  0
}
