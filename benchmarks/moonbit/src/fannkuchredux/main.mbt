fn main {
  let n = 10
  let perm = Array::make(n, 0)
  let perm1 = Array::make(n, 0)
  let count = Array::make(n, 0)
  for i = 0; i < n; i = i + 1 {
    perm1[i] = i
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
    for i = 0; i < n; i = i + 1 {
      perm[i] = perm1[i]
    }
    let mut flips = 0
    let mut k = perm[0]
    while k != 0 {
      let k2 = (k + 1) >> 1
      for i = 0; i < k2; i = i + 1 {
        let tmp = perm[i]
        perm[i] = perm[k - i]
        perm[k - i] = tmp
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
      for i = 0; i < r; i = i + 1 {
        perm1[i] = perm1[i + 1]
      }
      perm1[r] = perm0
      count[r] = count[r] - 1
      if count[r] > 0 {
        break
      }
      r = r + 1
    }
  }
  println(checksum.to_string() + " " + max_flips.to_string())
}
