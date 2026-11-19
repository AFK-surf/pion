const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn atoi(s: [*:0]const u8) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const WorkerArg = struct {
    n: usize,
    y_start: usize,
    y_end: usize,
    in_set: i32,
    xhash: i32,
};

fn computeStripe(a: *WorkerArg) void {
    const n = a.n;
    const inv_n: f64 = 2.0 / @as(f64, @floatFromInt(n));
    var in_set: i32 = 0;
    var xhash: i32 = 0;

    var y: usize = a.y_start;
    while (y < a.y_end) : (y += 1) {
        const ci: f64 = @as(f64, @floatFromInt(y)) * inv_n - 1.0;
        var row_h: i32 = 0;
        var byte_acc: i32 = 0;
        var bit_num: u5 = 0;
        var x: usize = 0;
        while (x < n) : (x += 1) {
            const cr: f64 = @as(f64, @floatFromInt(x)) * inv_n - 1.5;
            var zr: f64 = 0.0;
            var zi: f64 = 0.0;
            var escaped: bool = false;
            var iter: usize = 0;
            while (iter < 50) : (iter += 1) {
                const tr = zr * zr - zi * zi + cr;
                const ti = 2.0 * zr * zi + ci;
                zr = tr;
                zi = ti;
                if (zr * zr + zi * zi > 4.0) {
                    escaped = true;
                    break;
                }
            }
            byte_acc = (byte_acc << 1) | @as(i32, if (escaped) 0 else 1);
            if (!escaped) in_set += 1;
            bit_num += 1;
            if (bit_num == 8) {
                row_h = (row_h *% 31 +% byte_acc) & 0x3fffffff;
                byte_acc = 0;
                bit_num = 0;
            }
        }
        if (bit_num > 0) {
            byte_acc <<= (8 - bit_num);
            row_h = (row_h *% 31 +% byte_acc) & 0x3fffffff;
        }
        const yi: i32 = @intCast(y);
        const row_mix = (row_h ^ ((yi *% 2654435) & 0x3fffffff)) & 0x3fffffff;
        xhash ^= row_mix;
    }

    a.in_set = in_set;
    a.xhash = xhash;
}

pub fn main() !void {
    var threads: usize = 1;
    const n: usize = 4000;
    if (getenv("BENCH_THREADS")) |ts| {
        const t = atoi(ts);
        if (t >= 1 and t <= 64) threads = @intCast(t);
    }

    if (threads == 1) {
        var a = WorkerArg{ .n = n, .y_start = 0, .y_end = n, .in_set = 0, .xhash = 0 };
        computeStripe(&a);
        _ = printf("%d %d\n", a.in_set, a.xhash);
        return;
    }

    var args: [64]WorkerArg = undefined;
    var handles: [64]std.Thread = undefined;
    for (0..threads) |t| {
        args[t] = .{
            .n = n,
            .y_start = (n * t) / threads,
            .y_end = (n * (t + 1)) / threads,
            .in_set = 0,
            .xhash = 0,
        };
        handles[t] = try std.Thread.spawn(.{}, computeStripe, .{&args[t]});
    }

    var total_in_set: i32 = 0;
    var total_xhash: i32 = 0;
    for (0..threads) |t| {
        handles[t].join();
        total_in_set += args[t].in_set;
        total_xhash ^= args[t].xhash;
    }

    _ = printf("%d %d\n", total_in_set, total_xhash);
}
