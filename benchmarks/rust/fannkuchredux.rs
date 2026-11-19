fn main() {
    let n: usize = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(10);
    let mut perm: Vec<usize> = vec![0; n];
    let mut perm1: Vec<usize> = (0..n).collect();
    let mut count: Vec<usize> = vec![0; n];

    let mut max_flips: i32 = 0;
    let mut checksum: i32 = 0;
    let mut perm_count: usize = 0;
    let mut r = n;

    loop {
        while r != 1 {
            count[r - 1] = r;
            r -= 1;
        }

        perm.copy_from_slice(&perm1);

        let mut flips: i32 = 0;
        let mut k = perm[0];
        while k != 0 {
            let k2 = (k + 1) >> 1;
            for i in 0..k2 {
                perm.swap(i, k - i);
            }
            flips += 1;
            k = perm[0];
        }

        if flips > max_flips {
            max_flips = flips;
        }
        if (perm_count & 1) == 0 {
            checksum += flips;
        } else {
            checksum -= flips;
        }
        perm_count += 1;

        loop {
            if r == n {
                println!("{} {}", checksum, max_flips);
                return;
            }
            let perm0 = perm1[0];
            for i in 0..r {
                perm1[i] = perm1[i + 1];
            }
            perm1[r] = perm0;
            count[r] -= 1;
            if count[r] > 0 {
                break;
            }
            r += 1;
        }
    }
}
