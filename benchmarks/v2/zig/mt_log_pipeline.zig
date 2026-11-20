// V2 Benchmark 3: mt_log_pipeline (Zig 0.17.1, std.Thread + pthread mutex/cond bounded channel)
// Usage: mt_log_pipeline <logs.txt> [1|4]
const std = @import("std");

extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;
extern "c" fn atoi(s: [*:0]const u8) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fseek(stream: *anyopaque, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *anyopaque) c_long;
extern "c" fn rewind(stream: *anyopaque) void;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;

const SEEK_END: c_int = 2;

const StrChan = struct {
    buf: [][]u8,
    cap: usize,
    head: usize,
    tail: usize,
    count: usize,
    closed: bool,
    mu: std.c.pthread_mutex_t,
    not_empty: std.c.pthread_cond_t,
    not_full: std.c.pthread_cond_t,

    fn init(alloc: std.mem.Allocator, cap: usize) !StrChan {
        const buf = try alloc.alloc([]u8, cap);
        var ch = StrChan{
            .buf = buf,
            .cap = cap,
            .head = 0,
            .tail = 0,
            .count = 0,
            .closed = false,
            .mu = std.c.PTHREAD_MUTEX_INITIALIZER,
            .not_empty = std.c.PTHREAD_COND_INITIALIZER,
            .not_full = std.c.PTHREAD_COND_INITIALIZER,
        };
        _ = &ch;
        return ch;
    }

    fn deinit(self: *StrChan, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }

    fn send(self: *StrChan, s: []u8) bool {
        _ = std.c.pthread_mutex_lock(&self.mu);
        while (self.count == self.cap and !self.closed) {
            _ = std.c.pthread_cond_wait(&self.not_full, &self.mu);
        }
        if (self.closed) {
            _ = std.c.pthread_mutex_unlock(&self.mu);
            return false;
        }
        self.buf[self.tail] = s;
        self.tail = (self.tail + 1) % self.cap;
        self.count += 1;
        _ = std.c.pthread_cond_signal(&self.not_empty);
        _ = std.c.pthread_mutex_unlock(&self.mu);
        return true;
    }

    fn recv(self: *StrChan) ?[]u8 {
        _ = std.c.pthread_mutex_lock(&self.mu);
        while (self.count == 0 and !self.closed) {
            _ = std.c.pthread_cond_wait(&self.not_empty, &self.mu);
        }
        if (self.count == 0 and self.closed) {
            _ = std.c.pthread_mutex_unlock(&self.mu);
            return null;
        }
        const s = self.buf[self.head];
        self.head = (self.head + 1) % self.cap;
        self.count -= 1;
        _ = std.c.pthread_cond_signal(&self.not_full);
        _ = std.c.pthread_mutex_unlock(&self.mu);
        return s;
    }

    fn close(self: *StrChan) void {
        _ = std.c.pthread_mutex_lock(&self.mu);
        self.closed = true;
        _ = std.c.pthread_cond_broadcast(&self.not_empty);
        _ = std.c.pthread_cond_broadcast(&self.not_full);
        _ = std.c.pthread_mutex_unlock(&self.mu);
    }
};

const WorkerStats = struct {
    lines: i32 = 0,
    errs: i32 = 0,
    slow: i32 = 0,
    sum_lat: i64 = 0,
    svc_sum: i64 = 0,
    msg_xor: i32 = 0,
};

const ProducerArg = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    work_ch: *StrChan,
};

const WorkerArg = struct {
    alloc: std.mem.Allocator,
    work_ch: *StrChan,
    alert_ch: *StrChan,
    active_workers: *std.atomic.Value(i32),
    stats: WorkerStats = .{},
};

fn polyHash(s: []const u8) i32 {
    var h: u32 = 0;
    for (s) |b| {
        h = (h *% 31 +% @as(u32, b)) & 0x3fffffff;
    }
    return @intCast(h);
}

fn producerFn(pa: *ProducerArg) void {
    const s = pa.src;
    const n = s.len;
    var pos: usize = 0;
    while (pos < n) {
        const start = pos;
        var nl: usize = 0;
        while (pos < n and nl < 10) {
            if (s[pos] == '\n') nl += 1;
            pos += 1;
        }
        const chunk = pa.alloc.dupe(u8, s[start..pos]) catch unreachable;
        _ = pa.work_ch.send(chunk);
    }
    pa.work_ch.close();
}

fn workerFn(wa: *WorkerArg) void {
    const alloc = wa.alloc;
    var svc_lat = std.StringHashMap(i64).init(alloc);
    defer {
        var it = svc_lat.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        svc_lat.deinit();
    }

    var lines: i32 = 0;
    var errs: i32 = 0;
    var slow: i32 = 0;
    var sum_lat: i64 = 0;
    var msg_xor: i32 = 0;
    var lat_buf: [32]u8 = undefined;

    while (wa.work_ch.recv()) |chunk| {
        defer alloc.free(chunk);
        const s = chunk;
        const n = s.len;
        var i: usize = 0;
        while (i < n) {
            const line_start = i;
            while (i < n and s[i] != '\n') i += 1;
            const line_end = i;
            if (i < n and s[i] == '\n') i += 1;
            if (line_end <= line_start) continue;

            lines += 1;
            var p = line_start;
            while (p < line_end and s[p] != ' ') p += 1;
            if (p < line_end) p += 1;
            p += 6; // level=
            const lvl_s = p;
            while (p < line_end and s[p] != ' ') p += 1;
            const lvl_e = p;
            if (p < line_end) p += 1;
            p += 4; // svc=
            const svc_s = p;
            while (p < line_end and s[p] != ' ') p += 1;
            const svc_e = p;
            if (p < line_end) p += 1;
            p += 4; // lat=
            var lat: i32 = 0;
            while (p < line_end and s[p] != ' ') {
                lat = lat * 10 + @as(i32, s[p] - '0');
                p += 1;
            }
            if (p < line_end) p += 1;
            p += 4; // msg=
            const msg_s = p;

            const lat64: i64 = lat;
            sum_lat += lat64;
            const svc = s[svc_s..svc_e];
            if (svc_lat.getPtr(svc)) |ptr| {
                ptr.* += lat64;
            } else {
                const owned = alloc.dupe(u8, svc) catch unreachable;
                svc_lat.put(owned, lat64) catch unreachable;
            }
            msg_xor ^= polyHash(s[msg_s..line_end]);

            const is_err = (lvl_e - lvl_s == 3) and s[lvl_s] == 'E' and s[lvl_s + 1] == 'R' and s[lvl_s + 2] == 'R';
            const is_slow = lat >= 500;
            if (is_err) errs += 1;
            if (is_slow) slow += 1;
            if (is_err or is_slow) {
                const lvl = s[lvl_s..lvl_e];
                const msg = s[msg_s..line_end];
                const lat_str = std.fmt.bufPrint(&lat_buf, "{d}", .{lat}) catch unreachable;
                const alen = 6 + svc.len + 1 + lvl.len + 1 + lat_str.len + 1 + msg.len;
                const abuf = alloc.alloc(u8, alen) catch unreachable;
                var off: usize = 0;
                @memcpy(abuf[off .. off + 6], "ALERT|"); off += 6;
                @memcpy(abuf[off .. off + svc.len], svc); off += svc.len;
                abuf[off] = '|'; off += 1;
                @memcpy(abuf[off .. off + lvl.len], lvl); off += lvl.len;
                abuf[off] = '|'; off += 1;
                @memcpy(abuf[off .. off + lat_str.len], lat_str); off += lat_str.len;
                abuf[off] = '|'; off += 1;
                @memcpy(abuf[off .. off + msg.len], msg);
                _ = wa.alert_ch.send(abuf);
            }
        }
    }

    var svc_sum: i64 = 0;
    var it = svc_lat.valueIterator();
    while (it.next()) |v| svc_sum += v.*;

    wa.stats = .{
        .lines = lines,
        .errs = errs,
        .slow = slow,
        .sum_lat = sum_lat,
        .svc_sum = svc_sum,
        .msg_xor = msg_xor,
    };

    if (wa.active_workers.fetchSub(1, .acq_rel) == 1) {
        wa.alert_ch.close();
    }
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
    var nworkers: usize = 1;
    if (argc >= 3) {
        const t = atoi(argv[2]);
        if (t >= 1 and t <= 16) nworkers = @intCast(t);
    }

    const src = try readFileAll(alloc, argv[1]);
    defer alloc.free(src);

    var work_ch = try StrChan.init(alloc, 64);
    defer work_ch.deinit(alloc);
    var alert_ch = try StrChan.init(alloc, 256);
    defer alert_ch.deinit(alloc);

    var active = std.atomic.Value(i32).init(@intCast(nworkers));
    var parg = ProducerArg{ .alloc = alloc, .src = src, .work_ch = &work_ch };
    const prod_th = try std.Thread.spawn(.{}, producerFn, .{&parg});

    var wargs: [16]WorkerArg = undefined;
    var wths: [16]std.Thread = undefined;
    for (0..nworkers) |t| {
        wargs[t] = .{
            .alloc = alloc,
            .work_ch = &work_ch,
            .alert_ch = &alert_ch,
            .active_workers = &active,
        };
        wths[t] = try std.Thread.spawn(.{}, workerFn, .{&wargs[t]});
    }

    var alert_cnt: i32 = 0;
    var alert_len_sum: i64 = 0;
    var alert_xor: i32 = 0;
    while (alert_ch.recv()) |alert| {
        alert_cnt += 1;
        alert_len_sum += @intCast(alert.len);
        alert_xor ^= polyHash(alert);
        alloc.free(alert);
    }

    prod_th.join();
    var lines: i32 = 0;
    var errs: i32 = 0;
    var slow: i32 = 0;
    var sum_lat: i64 = 0;
    var svc_sum: i64 = 0;
    var msg_xor: i32 = 0;
    for (0..nworkers) |t| {
        wths[t].join();
        lines += wargs[t].stats.lines;
        errs += wargs[t].stats.errs;
        slow += wargs[t].stats.slow;
        sum_lat += wargs[t].stats.sum_lat;
        svc_sum += wargs[t].stats.svc_sum;
        msg_xor ^= wargs[t].stats.msg_xor;
    }
    if (svc_sum != sum_lat) return error.SvcSumMismatch;

    _ = printf("%d %d %d %lld %d %d %lld %d\n",
        lines, errs, slow, @as(c_longlong, sum_lat), msg_xor,
        alert_cnt, @as(c_longlong, alert_len_sum), alert_xor);
}
