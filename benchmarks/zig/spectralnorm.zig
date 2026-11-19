const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

inline fn evalA(i: usize, j: usize) f64 {
    const ij = i + j;
    return 1.0 / @as(f64, @floatFromInt(ij * (ij + 1) / 2 + i + 1));
}

fn evalATimesU(u: []const f64, au: []f64) void {
    const n = u.len;
    for (0..n) |i| {
        var sum: f64 = 0.0;
        for (0..n) |j| {
            sum += evalA(i, j) * u[j];
        }
        au[i] = sum;
    }
}

fn evalAtTimesU(u: []const f64, au: []f64) void {
    const n = u.len;
    for (0..n) |i| {
        var sum: f64 = 0.0;
        for (0..n) |j| {
            sum += evalA(j, i) * u[j];
        }
        au[i] = sum;
    }
}

fn evalAtATimesU(u: []const f64, atau: []f64, tmp: []f64) void {
    evalATimesU(u, tmp);
    evalAtTimesU(tmp, atau);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const n: usize = 2000;
    const u = try alloc.alloc(f64, n);
    defer alloc.free(u);
    const v = try alloc.alloc(f64, n);
    defer alloc.free(v);
    const tmp = try alloc.alloc(f64, n);
    defer alloc.free(tmp);

    for (u) |*x| x.* = 1.0;
    for (v) |*x| x.* = 0.0;

    for (0..10) |_| {
        evalAtATimesU(u, v, tmp);
        evalAtATimesU(v, u, tmp);
    }

    var vbv: f64 = 0.0;
    var vv: f64 = 0.0;
    for (0..n) |i| {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }

    _ = printf("%.9f\n", @sqrt(vbv / vv));
}
