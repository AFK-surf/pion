// V2 Benchmark 1: json_query (Zig 0.17.1, hand-written lexer + recursive-descent AST)
const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *anyopaque) c_long;
extern "c" fn rewind(stream: *anyopaque) void;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

const SEEK_END: c_int = 2;

const JsonEntry = struct {
    key: []u8,
    val: *JsonValue,
};

const JsonValue = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i32,
    str_val: []u8,
    arr_val: std.ArrayListUnmanaged(*JsonValue),
    obj_val: std.ArrayListUnmanaged(JsonEntry),
};

fn freeJson(alloc: std.mem.Allocator, v: *JsonValue) void {
    switch (v.*) {
        .str_val => |s| alloc.free(s),
        .arr_val => |*a| {
            for (a.items) |item| freeJson(alloc, item);
            a.deinit(alloc);
        },
        .obj_val => |*o| {
            for (o.items) |ent| {
                alloc.free(ent.key);
                freeJson(alloc, ent.val);
            }
            o.deinit(alloc);
        },
        else => {},
    }
    alloc.destroy(v);
}

const Parser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                self.pos += 1;
            } else break;
        }
    }

    fn parseStringRaw(self: *Parser) ![]u8 {
        self.pos += 1; // '"'
        const start = self.pos;
        var scan = start;
        var has_escape = false;
        while (scan < self.src.len) {
            const c = self.src[scan];
            if (c == '"') break;
            if (c == '\\') {
                has_escape = true;
                break;
            }
            scan += 1;
        }
        if (!has_escape) {
            const s = try self.alloc.dupe(u8, self.src[start..scan]);
            self.pos = scan + 1;
            return s;
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '"') {
                return try buf.toOwnedSlice(self.alloc);
            }
            if (c == '\\' and self.pos < self.src.len) {
                const e = self.src[self.pos];
                self.pos += 1;
                const ch: u8 = switch (e) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 8,
                    'f' => 12,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => e,
                };
                try buf.append(self.alloc, ch);
            } else {
                try buf.append(self.alloc, c);
            }
        }
        return error.UnterminatedString;
    }

    fn parseArray(self: *Parser) anyerror!*JsonValue {
        self.pos += 1; // '['
        var items: std.ArrayListUnmanaged(*JsonValue) = .empty;
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == ']') {
            self.pos += 1;
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .arr_val = items };
            return v;
        }
        while (self.pos < self.src.len) {
            const elem = try self.parseValue();
            try items.append(self.alloc, elem);
            self.skipWs();
            if (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (c == ',') {
                    self.pos += 1;
                    self.skipWs();
                } else if (c == ']') {
                    self.pos += 1;
                    const v = try self.alloc.create(JsonValue);
                    v.* = .{ .arr_val = items };
                    return v;
                } else return error.UnexpectedToken;
            }
        }
        return error.UnterminatedArray;
    }

    fn parseObject(self: *Parser) anyerror!*JsonValue {
        self.pos += 1; // '{'
        var entries: std.ArrayListUnmanaged(JsonEntry) = .empty;
        self.skipWs();
        if (self.pos < self.src.len and self.src[self.pos] == '}') {
            self.pos += 1;
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .obj_val = entries };
            return v;
        }
        while (self.pos < self.src.len) {
            self.skipWs();
            const key = try self.parseStringRaw();
            self.skipWs();
            self.pos += 1; // ':'
            const val = try self.parseValue();
            try entries.append(self.alloc, .{ .key = key, .val = val });
            self.skipWs();
            if (self.pos < self.src.len) {
                const c = self.src[self.pos];
                if (c == ',') {
                    self.pos += 1;
                    self.skipWs();
                } else if (c == '}') {
                    self.pos += 1;
                    const v = try self.alloc.create(JsonValue);
                    v.* = .{ .obj_val = entries };
                    return v;
                } else return error.UnexpectedToken;
            }
        }
        return error.UnterminatedObject;
    }

    fn parseValue(self: *Parser) anyerror!*JsonValue {
        self.skipWs();
        const c = self.src[self.pos];
        if (c == '{') return self.parseObject();
        if (c == '[') return self.parseArray();
        if (c == '"') {
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .str_val = try self.parseStringRaw() };
            return v;
        }
        if (c == 't') {
            self.pos += 4;
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .bool_val = true };
            return v;
        }
        if (c == 'f') {
            self.pos += 5;
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .bool_val = false };
            return v;
        }
        if (c == 'n') {
            self.pos += 4;
            const v = try self.alloc.create(JsonValue);
            v.* = .{ .null_val = {} };
            return v;
        }
        var neg = false;
        if (c == '-') {
            neg = true;
            self.pos += 1;
        }
        var acc: i32 = 0;
        while (self.pos < self.src.len) {
            const d = self.src[self.pos];
            if (d >= '0' and d <= '9') {
                acc = acc * 10 + @as(i32, d - '0');
                self.pos += 1;
            } else break;
        }
        const v = try self.alloc.create(JsonValue);
        v.* = .{ .int_val = if (neg) -acc else acc };
        return v;
    }
};

fn objGet(v: *JsonValue, key: []const u8) ?*JsonValue {
    switch (v.*) {
        .obj_val => |o| {
            for (o.items) |ent| {
                if (std.mem.eql(u8, ent.key, key)) return ent.val;
            }
            return null;
        },
        else => return null,
    }
}

fn mapInc(alloc: std.mem.Allocator, m: *std.StringHashMap(i32), key: []const u8) !void {
    if (m.getPtr(key)) |p| {
        p.* += 1;
    } else {
        const owned = try alloc.dupe(u8, key);
        try m.put(owned, 1);
    }
}

fn appendJsonEscaped(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
}

fn polyHash(s: []const u8) i32 {
    var h: u32 = 0;
    for (s) |b| {
        h = (h *% 31 +% @as(u32, b)) & 0x3fffffff;
    }
    return @intCast(h);
}

fn readFileAll(alloc: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const f = fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = fclose(f);
    _ = fseek(f, 0, SEEK_END);
    const fsz: usize = @intCast(ftell(f));
    rewind(f);
    const buf = try alloc.alloc(u8, fsz);
    const n = fread(buf.ptr, 1, fsz, f);
    return buf[0..n];
}

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    run(argc, argv) catch return 1;
    return 0;
}

fn run(argc: c_int, argv: [*][*:0]u8) !void {
    const alloc = std.heap.c_allocator;
    if (argc < 2) return error.MissingArg;
    const src = try readFileAll(alloc, argv[1]);
    defer alloc.free(src);

    var p = Parser{ .alloc = alloc, .src = src, .pos = 0 };
    const root = try p.parseValue();
    defer freeJson(alloc, root);

    const records_v = objGet(root, "records") orelse return error.MissingRecords;
    const records = records_v.arr_val.items;

    var role_counts = std.StringHashMap(i32).init(alloc);
    defer {
        var it = role_counts.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        role_counts.deinit();
    }
    var tag_counts = std.StringHashMap(i32).init(alloc);
    defer {
        var it = tag_counts.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        tag_counts.deinit();
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    var total: i32 = 0;
    var matched: i32 = 0;
    var sum_lat: i32 = 0;
    var nbuf: [32]u8 = undefined;

    for (records) |rec| {
        total += 1;
        const user = objGet(rec, "user").?;
        const metrics = objGet(rec, "metrics").?;
        const note = objGet(rec, "note").?.str_val;
        const id_val = objGet(user, "id").?.int_val;
        const role = objGet(user, "role").?.str_val;
        const active = objGet(user, "active").?.bool_val;
        const lat = objGet(metrics, "latency_ms").?.int_val;
        const tags = objGet(metrics, "tags").?.arr_val.items;

        try mapInc(alloc, &role_counts, role);
        var has_prod = false;
        for (tags) |tv| {
            const ts = tv.str_val;
            try mapInc(alloc, &tag_counts, ts);
            if (std.mem.eql(u8, ts, "prod")) has_prod = true;
        }
        if (active and lat >= 150 and has_prod) {
            matched += 1;
            sum_lat += lat;
            try out.appendSlice(alloc, "{\"id\":");
            const id_s = try std.fmt.bufPrint(&nbuf, "{d}", .{id_val});
            try out.appendSlice(alloc, id_s);
            try out.appendSlice(alloc, ",\"role\":\"");
            try appendJsonEscaped(alloc, &out, role);
            try out.appendSlice(alloc, "\",\"lat\":");
            const lat_s = try std.fmt.bufPrint(&nbuf, "{d}", .{lat});
            try out.appendSlice(alloc, lat_s);
            try out.appendSlice(alloc, ",\"note\":\"");
            try appendJsonEscaped(alloc, &out, note);
            try out.appendSlice(alloc, "\"}\n");
        }
    }

    var role_tag_hash: i32 = 0;
    {
        var it = role_counts.iterator();
        while (it.next()) |e| {
            const kh: u32 = @intCast(polyHash(e.key_ptr.*));
            const v: u32 = @bitCast(e.value_ptr.*);
            const eh: u32 = ((kh *% 17 +% v) ^ 0x13579) & 0x3fffffff;
            role_tag_hash ^= @intCast(eh);
        }
    }
    {
        var it = tag_counts.iterator();
        while (it.next()) |e| {
            const kh: u32 = @intCast(polyHash(e.key_ptr.*));
            const v: u32 = @bitCast(e.value_ptr.*);
            const eh: u32 = ((kh *% 29 +% v) ^ 0x2468a) & 0x3fffffff;
            role_tag_hash ^= @intCast(eh);
        }
    }

    const out_hash = polyHash(out.items);
    _ = printf("%d %d %d %d %zu %d\n", total, matched, sum_lat, role_tag_hash, out.items.len, out_hash);
}
