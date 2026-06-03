// kcp/Server.zig - an implementation of "fast and reliable" ARQ protocol in zig.
//
// CONTRIBUTORS:
// xeondev (https://github.com/thexeondev)
//
// REFERENCES:
// Reference Implementation in C: https://github.com/skywind3000/kcp
//
// Copyright (c) 2026 ReversedRooms
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <www.gnu.org>.

const min_rto: kcp.Timeval = .{ .milliseconds = 100 };
const max_rto: kcp.Timeval = .{ .milliseconds = 60000 };
const mss: usize = kcp.mtu - kcp.Header.size;

const SendRing = struct {
    // equal to client's rcvwnd
    pub const size: u32 = 256;

    sn: [size]u32,
    frg: [size]kcp.Header.Fragment,
    len: [size]u16,
    resend_ts: [size]kcp.Timeval,
    rto: [size]kcp.Timeval,
    fastack: [size]u8,
    xmit: [size]u8,
    buffers: [size][mss]u8,

    head: u32,
    tail: u32,

    pub fn reset(ring: *SendRing) void {
        @memset(&ring.sn, 0);

        ring.head = 0;
        ring.tail = 0;
    }

    pub fn pop(ring: *SendRing) ?u32 {
        while (ring.head != ring.tail) {
            defer ring.head += 1;

            if (ring.sn[ring.head % SendRing.size] == ring.head)
                return ring.head % SendRing.size;
        }

        return null;
    }

    pub fn unused(ring: *SendRing) u16 {
        return @truncate(SendRing.size - (ring.tail -% ring.head));
    }

    pub fn ack(ring: *SendRing, ack_sn: u32) void {
        if (ack_sn >= ring.head and ack_sn < ring.tail) {
            ring.sn[ack_sn % SendRing.size] = 0;

            while (ring.head < ring.tail and ring.sn[ring.head % SendRing.size] == 0)
                ring.head += 1;
        }
    }

    pub fn shiftUna(ring: *SendRing, una: u32) void {
        if (una > ring.tail) return;

        while (ring.head < una) : (ring.head += 1) {
            ring.sn[ring.head % SendRing.size] = 0;
        }
    }

    pub fn markFastack(ring: *SendRing, maxack: u32, current: kcp.Timeval) void {
        var sn = ring.head;
        while (sn < maxack) : (sn += 1) {
            const seg = sn % SendRing.size;
            if (ring.sn[seg] != sn) continue;

            if (ring.fastack[seg] != 0) {
                ring.fastack[seg] = 0;
                ring.resend_ts[seg] = current;
            } else {
                ring.fastack[seg] = 1;
            }
        }
    }
};

const RecvRing = struct {
    // equal to client's sndwnd
    pub const size: u32 = 512;

    frg: [size]kcp.Header.Fragment,
    sn: [size]u32,
    len: [size]u16,
    buffers: [size][mss]u8,

    head: u32,
    tail: u32,

    pub fn reset(ring: *RecvRing) void {
        @memset(&ring.sn, 0);

        ring.head = 0;
        ring.tail = 0;
    }

    pub fn pop(ring: *RecvRing) ?u32 {
        if (ring.head == ring.tail)
            return null;

        if (ring.sn[ring.head % size] != ring.head)
            return null;

        defer ring.head += 1;
        return ring.head % size;
    }

    pub fn unused(ring: *RecvRing) u16 {
        return @truncate(RecvRing.size - (ring.tail -% ring.head));
    }
};

const AckRing = struct {
    // equal to client's sndwnd
    pub const size: u32 = 512;

    pub const Entry = packed struct {
        sn: u32,
        ts: kcp.Timeval,
    };

    entries: [size]Entry,
    head: u16,
    tail: u16,

    pub fn push(ring: *AckRing, sn: u32, ts: kcp.Timeval) void {
        defer ring.tail += 1;
        ring.entries[ring.tail] = .{ .sn = sn, .ts = ts };
    }

    pub fn pop(ring: *AckRing) ?Entry {
        if (ring.head == ring.tail) return null;

        defer ring.head += 1;
        return ring.entries[ring.head];
    }

    pub fn reset(ring: *AckRing) void {
        ring.head = 0;
        ring.tail = 0;
    }
};

const Conversations = struct {
    ids: []kcp.ConvId,
    tokens: []kcp.Token,
    nodes: []List.Node,
    rings: []*Rings,

    start_time: []kcp.Timeval,
    last_update: []kcp.Timeval,

    rx_rttval: []u32,
    rx_srtt: []kcp.Timeval,
    rx_rto: []kcp.Timeval,

    const Rings = struct {
        send: SendRing,
        recv: RecvRing,
        ack: AckRing,
    };

    const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        pub fn toInt(oi: OptionalIndex) u32 {
            debug.assert(oi != .none);
            return @intFromEnum(oi);
        }
    };

    const List = struct {
        head: OptionalIndex,

        pub const empty: List = .{ .head = .none };

        pub const Node = struct { next: OptionalIndex };
    };

    pub fn initAlloc(
        uninit: *Conversations,
        arena: Allocator,
        capacity: usize,
    ) Allocator.Error!void {
        inline for (@typeInfo(Conversations).@"struct".fields) |field|
            @field(uninit, field.name) = try arena.alloc(@typeInfo(field.type).pointer.child, capacity);

        for (uninit.nodes[0 .. capacity - 1], 1..) |*node, next|
            node.next = @enumFromInt(@as(u32, @intCast(next)));

        uninit.nodes[capacity - 1].next = .none;
    }
};

arena: heap.ArenaAllocator,
conversations: Conversations,
free: Conversations.List,
rings_pool: heap.MemoryPool(Conversations.Rings),

pub fn initAlloc(uninit: *Server, gpa: Allocator, slots: usize) Allocator.Error!void {
    uninit.arena = .init(gpa);
    errdefer uninit.arena.deinit();

    try uninit.conversations.initAlloc(uninit.arena.allocator(), slots);
    uninit.free = .{ .head = @enumFromInt(0) };

    uninit.rings_pool = .empty;
}

pub fn deinit(server: *Server) void {
    server.rings_pool.deinit(server.arena.child_allocator);
    server.arena.deinit();
}

pub fn release(server: *Server, conv_idx: u32) void {
    server.rings_pool.destroy(@alignCast(server.conversations.rings[conv_idx]));

    server.conversations.nodes[conv_idx].next = server.free.head;
    server.free.head = @enumFromInt(conv_idx);
}

pub fn create(
    server: *Server,
    conv_id: kcp.ConvId,
    token: kcp.Token,
    start_time: posix.timespec,
) Allocator.Error!Conversations.OptionalIndex {
    const index = switch (server.free.head) {
        .none => return .none,
        _ => |free| free: {
            const index = free.toInt();
            server.free.head = server.conversations.nodes[index].next;
            server.conversations.nodes[index].next = .none;
            break :free index;
        },
    };

    errdefer {
        server.conversations.nodes[index].next = server.free.head;
        server.free.head = @enumFromInt(index);
    }

    const rings = try server.rings_pool.create(server.arena.child_allocator);
    errdefer comptime unreachable;

    rings.send.reset();
    rings.recv.reset();
    rings.ack.reset();
    server.conversations.rings[index] = rings;

    server.conversations.ids[index] = conv_id;
    server.conversations.tokens[index] = token;

    server.conversations.start_time[index] = .fromTimespec(start_time);
    server.conversations.last_update[index] = .zero;

    server.conversations.rx_rttval[index] = 0;
    server.conversations.rx_srtt[index] = .zero;
    server.conversations.rx_rto[index] = .zero;

    return @enumFromInt(index);
}

pub const SegReader = struct {
    ring: *RecvRing,
    /// Current Seg index.
    cur: u32,
    /// The amount of bytes "stolen" from next Seg's buffer.
    seek_next: usize,
    interface: Io.Reader,

    pub fn init(ring: *RecvRing) SegReader {
        const head = ring.head % RecvRing.size;

        return .{
            .ring = ring,
            .cur = head,
            .seek_next = 0,
            .interface = .{
                .vtable = &.{
                    .stream = SegReader.stream,
                    .readVec = SegReader.readVec,
                    .rebase = SegReader.rebase,
                },
                .buffer = &ring.buffers[head],
                .end = ring.len[head],
                .seek = 0,
            },
        };
    }

    fn stream(io_r: *Io.Reader, _: *Io.Writer, _: Io.Limit) Io.Reader.StreamError!usize {
        try nextBuffer(io_r);
        return 0;
    }

    fn readVec(io_r: *Io.Reader, _: [][]u8) Io.Reader.Error!usize {
        try nextBuffer(io_r);
        return 0;
    }

    fn rebase(io_r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        const segs: *SegReader = @alignCast(@fieldParentPtr("interface", io_r));

        switch (segs.ring.frg[segs.cur]) {
            .last => return error.EndOfStream,
            _ => {
                // This means that rebase was called repeatedly. Should not happen.
                if (segs.seek_next != 0)
                    return error.ReadFailed;

                // Copy the leftover buffered data to the beginning of current buffer.
                const leftover = io_r.end - io_r.seek;
                @memmove(io_r.buffer[0..leftover], io_r.buffer[io_r.seek..io_r.end]);

                io_r.seek = 0;
                io_r.end = leftover;

                // Steal some data from the next buffer.
                const next_seg = (segs.cur + 1) % RecvRing.size;
                const next_buffer = segs.ring.buffers[next_seg][0..segs.ring.len[next_seg]];

                if (capacity > io_r.end + next_buffer.len)
                    return error.EndOfStream;

                @memcpy(io_r.buffer[leftover..capacity], next_buffer[0 .. capacity - leftover]);
                io_r.end = capacity;
                segs.seek_next = capacity - leftover;
            },
        }
    }

    fn nextBuffer(io_r: *Io.Reader) Io.Reader.Error!void {
        if (io_r.seek != io_r.end) return;
        const segs: *SegReader = @alignCast(@fieldParentPtr("interface", io_r));

        switch (segs.ring.frg[segs.cur]) {
            .last => return error.EndOfStream,
            _ => {
                segs.cur = (segs.cur + 1) % RecvRing.size;
                io_r.buffer = &segs.ring.buffers[segs.cur];
                io_r.end = segs.ring.len[segs.cur];
                io_r.seek = segs.seek_next;
                segs.seek_next = 0;
            },
        }
    }
};

pub fn reader(s: *Server, client: u32) ?SegReader {
    _ = s.peekSize(client) orelse return null;
    return .init(&s.conversations.rings[client].recv);
}

pub fn toss(s: *Server, client: u32) void {
    const ring = &s.conversations.rings[client].recv;

    while (ring.pop()) |index| {
        ring.sn[index] = 0;

        switch (ring.frg[index]) {
            .last => break,
            _ => {},
        }
    }
}

pub fn peekSize(s: *Server, client: u32) ?usize {
    const ring = &s.conversations.rings[client].recv;

    const ring_head = ring.head;
    defer ring.head = ring_head;

    const first = ring.pop() orelse return null;

    return switch (ring.frg[first]) {
        .last => ring.len[first],
        _ => {
            var len = ring.len[first];
            while (ring.pop()) |index| {
                switch (ring.frg[index]) {
                    .last => return len + ring.len[index],
                    _ => len += ring.len[index],
                }
            } else return null;
        },
    };
}

pub const SegWriter = struct {
    ring: *SendRing,
    cur: usize,
    interface: Io.Writer,

    pub fn init(ring: *SendRing, first: u32) SegWriter {
        return .{
            .ring = ring,
            .cur = first,
            .interface = .{
                .buffer = &ring.buffers[first % SendRing.size],
                .vtable = &.{ .drain = SegWriter.drain },
            },
        };
    }

    pub fn drain(io_w: *Io.Writer, _: []const []const u8, _: usize) Io.Writer.Error!usize {
        if (io_w.end != io_w.buffer.len) return 0;

        const seg_w: *SegWriter = @alignCast(@fieldParentPtr("interface", io_w));
        if (seg_w.cur == seg_w.ring.tail - 1) return error.WriteFailed;

        seg_w.cur += 1;
        const index = seg_w.cur % SendRing.size;

        io_w.buffer = &seg_w.ring.buffers[index];
        io_w.end = 0;

        return 0;
    }
};

pub fn allocPushSegments(s: *Server, client: u32, amount: usize) !u32 {
    const ring = &s.conversations.rings[client].send;

    var count: usize = (amount + mss - 1) / mss;

    if (count >= ring.unused())
        return error.MessageOversize;

    var full_size = amount;
    const first: u32 = ring.tail;

    while (count > 0) : ({
        count -= 1;
        ring.tail += 1;
        full_size -|= mss;
    }) {
        const index = ring.tail % SendRing.size;

        ring.sn[index] = ring.tail;
        ring.frg[index] = @enumFromInt(count - 1);
        ring.len[index] = @truncate(@min(mss, full_size));
        ring.resend_ts[index] = .zero;
        ring.rto[index] = .zero;
        ring.fastack[index] = 0;
        ring.xmit[index] = 0;
    }

    return first;
}

pub fn refreshRtt(s: *Server, client: u32, rtt_ms: u32) void {
    var rto: u32 = 0;

    const rx_srtt = &s.conversations.rx_srtt[client];
    const rx_rttval = &s.conversations.rx_rttval[client];
    const rx_rto = &s.conversations.rx_rto[client];

    if (rx_srtt.milliseconds == 0) {
        rx_srtt.milliseconds = rtt_ms;
        rx_rttval.* = @divTrunc(rtt_ms, 2);
    } else {
        const delta_i: i32 = @bitCast(rtt_ms -% rx_srtt.milliseconds);
        const delta: u32 = @intCast(if (delta_i < 0) -delta_i else delta_i);

        rx_rttval.* = @divTrunc((3 * rx_rttval.* + delta), 4);
        rx_srtt.milliseconds = @divTrunc((7 * rx_srtt.milliseconds + rtt_ms), 8);
        rx_srtt.milliseconds = @max(rx_srtt.milliseconds, 1);
    }

    const interval: u32 = 100;
    rto = rx_srtt.milliseconds + @max(
        interval,
        4 * rx_rttval.*,
    );

    rx_rto.milliseconds = std.math.clamp(
        rto,
        min_rto.milliseconds,
        max_rto.milliseconds,
    );
}

pub fn input(server: *Server, client_index: u32, data: []const u8) !void {
    const current = server.conversations.last_update[client_index];
    const rings = server.conversations.rings[client_index];

    var maxack: u32 = 0;
    var latest_ts: kcp.Timeval = .zero;
    var has_acks: bool = false;

    var buf_reader: Io.Reader = .fixed(data);

    while (buf_reader.bufferedLen() >= kcp.Header.size) {
        const header = try kcp.Header.decode(buf_reader.takeArray(kcp.Header.size) catch unreachable);
        const buf = try buf_reader.take(header.len);

        rings.send.shiftUna(header.una);

        switch (header.cmd) {
            .ack => {
                if (current.milliseconds >= header.ts.milliseconds)
                    server.refreshRtt(client_index, current.milliseconds - header.ts.milliseconds);

                rings.send.ack(header.sn);

                if (!has_acks) {
                    has_acks = true;
                    maxack = header.sn;
                    latest_ts = header.ts;
                } else if (header.sn > maxack and header.ts.milliseconds > latest_ts.milliseconds) {
                    maxack = header.sn;
                    latest_ts = header.ts;
                }
            },
            .push => {
                if (header.sn >= rings.recv.tail and header.sn < rings.recv.tail + RecvRing.size) {
                    const seg = header.sn % RecvRing.size;

                    if (rings.recv.sn[seg] != header.sn or header.sn == rings.recv.tail) {
                        rings.recv.sn[seg] = header.sn;
                        rings.recv.frg[seg] = header.frg;
                        rings.recv.len[seg] = @intCast(header.len);
                        @memcpy(rings.recv.buffers[seg][0..buf.len], buf);
                    }

                    while (rings.recv.sn[rings.recv.tail % RecvRing.size] == rings.recv.tail)
                        rings.recv.tail += 1;

                    rings.ack.push(header.sn, header.ts);
                }
            },
            .wask, .wins => {},
        }
    }

    if (has_acks)
        rings.send.markFastack(maxack, latest_ts);
}

// Drains outgoing segment queue into user-provided `output` buffer.
// Returns the amount of bytes drained.
// This function should be called repeatedly, until it returns zero.
// Once zero is returned, the caller *must* reset send ring head to the one before drain loop.
pub fn drain(s: *Server, client: u32, output: *[kcp.mtu]u8) usize {
    const conv_id = s.conversations.ids[client];
    const token = s.conversations.tokens[client].downgrade();

    const current = s.conversations.last_update[client];
    const rings = s.conversations.rings[client];

    const wnd = rings.recv.unused();
    const una = rings.recv.tail;

    var writer: Io.Writer = .fixed(output);
    var ack_header: kcp.Header = .{
        .conv_id = conv_id,
        .token = token,
        .cmd = .ack,
        .frg = .last,
        .wnd = wnd,
        .ts = .zero,
        .sn = 0,
        .una = una,
        .len = 0,
    };

    while (rings.ack.pop()) |entry| {
        if (writer.end + kcp.Header.size > kcp.mtu) {
            rings.ack.head -= 1;
            return writer.end;
        }

        ack_header.sn = entry.sn;
        ack_header.ts = entry.ts;
        ack_header.encode(&writer) catch unreachable;
    }

    rings.ack.reset();

    const rx_rto = s.conversations.rx_rto[client];

    while (rings.send.pop()) |index| {
        const retransmit = rings.send.xmit[index] != 0;

        if (!retransmit or current.milliseconds >= rings.send.resend_ts[index].milliseconds) {
            const len = rings.send.len[index];
            if (writer.end + len + kcp.Header.size > kcp.mtu) {
                rings.send.head -= 1; // we'll send it on the next `drain` call.
                return writer.end;
            }

            if (retransmit) {
                rings.send.rto[index].milliseconds += rings.send.rto[index].milliseconds / 2;
                rings.send.resend_ts[index].milliseconds = current.milliseconds + rings.send.rto[index].milliseconds;
                rings.send.fastack[index] = 0;
            } else {
                rings.send.resend_ts[index].milliseconds = current.milliseconds + rx_rto.milliseconds;
                rings.send.rto[index] = rx_rto;
            }

            rings.send.xmit[index] += 1;

            const header: kcp.Header = .{
                .conv_id = conv_id,
                .token = token,
                .cmd = .push,
                .frg = rings.send.frg[index],
                .wnd = wnd,
                .ts = current,
                .sn = rings.send.sn[index],
                .una = una,
                .len = rings.send.len[index],
            };

            header.encode(&writer) catch unreachable;
            writer.writeAll(rings.send.buffers[index][0..header.len]) catch unreachable;
        }
    }

    return writer.end;
}

pub fn update(s: *Server, client: u32, current_time: posix.timespec) void {
    const start = s.conversations.start_time[client];
    const current: kcp.Timeval = .fromTimespec(current_time);

    s.conversations.last_update[client].milliseconds = current.milliseconds -| start.milliseconds;
    const ring = &s.conversations.rings[client].send;

    // Update `ring.head`
    if (ring.pop() != null)
        ring.head -= 1;
}

const Io = std.Io;
const Allocator = std.mem.Allocator;

const posix = rmio.posix;
const heap = std.heap;
const debug = std.debug;

const kcp = @import("../kcp.zig");

const rmio = @import("rmio");
const std = @import("std");
const Server = @This();
