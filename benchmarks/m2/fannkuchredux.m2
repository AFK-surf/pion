///| Benchmarks Game: Fannkuch-Redux (N = 10) in m2
pub fn main(world : World) -> Int {
  let n = 10
  let perm : Array[Int] = []
  let perm1 : Array[Int] = []
  let count : Array[Int] = []
  let mut init = 0
  while init < n {
    perm.push(0)
    perm1.push(init)
    count.push(0)
    init = init + 1
  }
  let mut max_flips = 0
  let mut checksum = 0
  let mut perm_count = 0
  let mut r = n
  let mut done = false
  while !done {
    while r != 1 {
      count[r - 1] = r
      r = r - 1
    }
    let mut ci = 0
    while ci < n {
      perm[ci] = perm1[ci]
      ci = ci + 1
    }
    let mut flips = 0
    let mut k = perm[0]
    while k != 0 {
      let k2 = (k + 1) >> 1
      let mut fi = 0
      while fi < k2 {
        let tmp = perm[fi]
        perm[fi] = perm[k - fi]
        perm[k - fi] = tmp
        fi = fi + 1
      }
      flips = flips + 1
      k = perm[0]
    }
    if flips > max_flips {
      max_flips = flips
    }
    if (perm_count & 1) == 0 {
      checksum = checksum + flips
    } else {
      checksum = checksum - flips
    }
    perm_count = perm_count + 1
    while true {
      if r == n {
        done = true
        break
      }
      let perm0 = perm1[0]
      let mut si = 0
      while si < r {
        perm1[si] = perm1[si + 1]
        si = si + 1
      }
      perm1[r] = perm0
      count[r] = count[r] - 1
      if count[r] > 0 {
        break
      }
      r = r + 1
    }
  }
  io_println(world, checksum.to_string() + " " + max_flips.to_string())
  0
}
