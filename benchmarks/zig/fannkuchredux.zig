const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const n: usize = 10;
    const perm = try alloc.alloc(usize, n);
    defer alloc.free(perm);
    const perm1 = try alloc.alloc(usize, n);
    defer alloc.free(perm1);
    const count = try alloc.alloc(usize, n);
    defer alloc.free(count);

    for (0..n) |i| perm1[i] = i;

    var max_flips: i32 = 0;
    var checksum: i32 = 0;
    var perm_count: usize = 0;
    var r: usize = n;

    while (true) {
        while (r != 1) {
            count[r - 1] = r;
            r -= 1;
        }

        @memcpy(perm, perm1);

        var flips: i32 = 0;
        var k: usize = perm[0];
        while (k != 0) {
            const k2 = (k + 1) >> 1;
            var i: usize = 0;
            while (i < k2) : (i += 1) {
                const tmp = perm[i];
                perm[i] = perm[k - i];
                perm[k - i] = tmp;
            }
            flips += 1;
            k = perm[0];
        }

        if (flips > max_flips) max_flips = flips;
        if ((perm_count & 1) == 0) {
            checksum += flips;
        } else {
            checksum -= flips;
        }
        perm_count += 1;

        while (true) {
            if (r == n) {
                _ = printf("%d %d\n", checksum, max_flips);
                return;
            }
            const perm0 = perm1[0];
            var i: usize = 0;
            while (i < r) : (i += 1) {
                perm1[i] = perm1[i + 1];
            }
            perm1[r] = perm0;
            count[r] -= 1;
            if (count[r] > 0) break;
            r += 1;
        }
    }
}
