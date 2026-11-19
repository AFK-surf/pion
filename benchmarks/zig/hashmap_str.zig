const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const n: i32 = 100_000;

    var map = std.StringHashMap(i32).init(alloc);
    defer {
        var it = map.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        map.deinit();
    }

    var kbuf: [64]u8 = undefined;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const tag: i32 = (i *% 2654435) & 0xffff;
        const ks = try std.fmt.bufPrint(&kbuf, "k_{d}_{d}", .{ i, tag });
        const owned = try alloc.dupe(u8, ks);
        const val: i32 = (i *% 7 +% 13) & 0x3fffffff;
        try map.put(owned, val);
    }

    var hits: i32 = 0;
    var val_sum: i32 = 0;
    var round: i32 = 0;
    while (round < 2) : (round += 1) {
        i = 0;
        while (i < n) : (i += 1) {
            const tag: i32 = (i *% 2654435) & 0xffff;
            const ks = try std.fmt.bufPrint(&kbuf, "k_{d}_{d}", .{ i, tag });
            if (map.get(ks)) |v| {
                hits += 1;
                val_sum = (val_sum +% v) & 0x3fffffff;
            }
            const ms = try std.fmt.bufPrint(&kbuf, "miss_{d}", .{i});
            if (map.get(ms)) |v| {
                hits += 1;
                val_sum = (val_sum +% v) & 0x3fffffff;
            }
        }
    }

    var sb: std.ArrayListUnmanaged(u8) = .empty;
    defer sb.deinit(alloc);
    var vbuf: [64]u8 = undefined;
    i = 0;
    while (i < n) : (i += 10) {
        const tag: i32 = (i *% 2654435) & 0xffff;
        const ks = try std.fmt.bufPrint(&kbuf, "k_{d}_{d}", .{ i, tag });
        if (map.get(ks)) |v| {
            try sb.appendSlice(alloc, ks);
            const vs = try std.fmt.bufPrint(&vbuf, "={d};", .{v});
            try sb.appendSlice(alloc, vs);
        }
    }

    var sb_hash: i32 = 0;
    for (sb.items) |b| {
        sb_hash = (sb_hash *% 31 +% @as(i32, b)) & 0x3fffffff;
    }

    _ = printf("%d %d %zu %d\n", hits, val_sum, sb.items.len, sb_hash);
}
