const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

const Node = struct {
    left: ?*Node,
    right: ?*Node,
};

fn makeTree(alloc: std.mem.Allocator, depth: i32) !*Node {
    const n = try alloc.create(Node);
    if (depth > 0) {
        n.left = try makeTree(alloc, depth - 1);
        n.right = try makeTree(alloc, depth - 1);
    } else {
        n.left = null;
        n.right = null;
    }
    return n;
}

fn checkTree(n: *const Node) i32 {
    if (n.left) |l| {
        return 1 + checkTree(l) + checkTree(n.right.?);
    }
    return 1;
}

fn freeTree(alloc: std.mem.Allocator, n: *Node) void {
    if (n.left) |l| {
        freeTree(alloc, l);
        freeTree(alloc, n.right.?);
    }
    alloc.destroy(n);
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const max_depth: i32 = 16;
    const min_depth: i32 = 4;

    const stretch = try makeTree(alloc, max_depth + 1);
    const stretch_check = checkTree(stretch);
    freeTree(alloc, stretch);

    const long_lived = try makeTree(alloc, max_depth);

    var total_check: i64 = 0;
    var depth: i32 = min_depth;
    while (depth <= max_depth) : (depth += 2) {
        const shift: u5 = @intCast(max_depth - depth + min_depth);
        const iterations: i32 = @as(i32, 1) << shift;
        var check: i32 = 0;
        var i: i32 = 0;
        while (i < iterations) : (i += 1) {
            const t = try makeTree(alloc, depth);
            check += checkTree(t);
            freeTree(alloc, t);
        }
        total_check += check;
    }

    const long_check = checkTree(long_lived);
    freeTree(alloc, long_lived);

    _ = printf("stretch=%d long=%d total=%lld\n", stretch_check, long_check, total_check);
}
