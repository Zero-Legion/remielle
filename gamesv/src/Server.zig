const log = std.log.scoped(.@"remielle-gamesv");

multi_conversation: kcp.MultiConversation,
cvars: ClientVariables,
output: OutputList,
conv_counter: kcp.ConvId.Counter,
/// ConvId -> session index
conv_map: array_hash_map.Auto(kcp.ConvId, u32),
/// Used for kcp tokens
conv_random: u64,
per_message_arena: *heap.ArenaAllocator,

pub const Frame = struct {
    target_index: u32,
    time: posix.timespec,
    cvars: *ClientVariables,
    multi_conversation: *kcp.MultiConversation,

    pub inline fn player(frame: *const Frame) logic.Properties.Player {
        return @enumFromInt(frame.target_index);
    }
};

pub fn initAlloc(
    uninit: *Server,
    /// Used for persistent server state allocations.
    arena: Allocator,
    /// Used for per-message allocations
    per_message_arena: *heap.ArenaAllocator,
    csprng: Random,
    max_concurrent_sessions: usize,
) Allocator.Error!void {
    try uninit.multi_conversation.initAlloc(arena, max_concurrent_sessions);
    try uninit.cvars.initAlloc(arena, max_concurrent_sessions);
    try uninit.output.initAlloc(arena, max_concurrent_sessions);

    uninit.conv_counter = .init;
    uninit.conv_map = .empty;
    try uninit.conv_map.ensureTotalCapacity(arena, max_concurrent_sessions);

    uninit.conv_random = csprng.int(u64);
    uninit.per_message_arena = per_message_arena;
}

pub fn receiveControlPacket(
    server: *Server,
    from: *const posix.Sockaddr,
    ctl: kcp.Control,
    out: *?[kcp.Control.size]u8,
) void {
    switch (ctl.kind()) {
        .connect => {
            const conv_id = server.conv_counter.next();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.in.addr),
            });

            out.* = @as([kcp.Control.size]u8, undefined);
            kcp.Control.encode(&out.*.?, .send_back_conv, conv_id, token.downgrade(), 0);
        },
        .disconnect => {
            const conv_id = ctl.conv();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.in.addr),
            });

            if (!ctl.isToken(token)) return;

            out.* = @as([kcp.Control.size]u8, undefined);
            kcp.Control.encode(&out.*.?, .disconnect, conv_id, token.downgrade(), 0);

            if (server.release(conv_id))
                log.debug("player from {f} disconnected", .{from});
        },
        .send_back_conv, _ => {}, // Clients should not send this
    }
}

pub fn onAuthSucceeded(
    server: *Server,
    /// Used for allocation of per-client ring buffers.
    /// The allocation will be recycled.
    arena: Allocator,
    from: *const posix.Sockaddr,
    first_packet: []u8,
    conv_id: kcp.ConvId,
    token: kcp.Token,
    current_time: posix.timespec,
    key: messaging.Xorpad.Key,
    auth_response: rmpb.main.PlayerGetTokenScRsp,
) !void {
    const client = switch (try server.multi_conversation.create(arena, conv_id, token, current_time)) {
        .none => return error.SessionLimitExceeded, // TODO: evict a client
        _ => |index| index.toInt(),
    };

    errdefer server.multi_conversation.destroy(client);

    // ACK the packet at kcp level
    server.multi_conversation.fillAt(client, first_packet) catch
        return error.InvalidFirstPacket;

    _ = server.multi_conversation.reader(client) orelse
        return error.InvalidFirstPacket;

    server.multi_conversation.discardAt(client);

    const length = messaging.encodingLength(.init, auth_response);
    var writer = try server.multi_conversation.writer(client, length);

    const cmd_id = comptime rmpb.cmdId(rmpb.main.PlayerGetTokenScRsp).?;
    messaging.encode(&writer.interface, .initial, cmd_id, .init, auth_response) catch unreachable;

    server.conv_map.putAssumeCapacity(conv_id, client);
    server.initAt(client, from.*, key);

    log.debug("player from {f} has logged in into account with uid {d}", .{ from, auth_response.uid });
}

pub const ReceiveStatus = union(enum) {
    success: void,
    /// The conversation ID and token are valid,
    /// but the authentication is not finished yet,
    /// this might be the first packet after connection request.
    unauthenticated: struct { header: kcp.Header, token: kcp.Token },
};

pub fn receiveKcpPacket(
    server: *Server,
    time: posix.timespec,
    from: *const posix.Sockaddr,
    buffer: []u8,
) !ReceiveStatus {
    const kcp_header = kcp.Header.decode(buffer[0..kcp.Header.size]) catch
        return error.MalformedPacket;

    if (kcp_header.conv_id == .none)
        return error.MalformedPacket;

    if (buffer.len < kcp_header.len + kcp.Header.size)
        return error.MalformedPacket;

    const token = kcp_header.token.upgrade(
        server.conv_random,
        @bitCast(from.in.addr),
        kcp_header.conv_id,
    ) orelse return error.InvalidToken;

    const client = server.conv_map.get(kcp_header.conv_id) orelse
        return .{ .unauthenticated = .{ .header = kcp_header, .token = token } };

    server.multi_conversation.fillAt(client, buffer) catch
        return error.FillFailed;

    const frame: Frame = .{
        .target_index = client,
        .time = time,
        .cvars = &server.cvars,
        .multi_conversation = &server.multi_conversation,
    };

    while (true) {
        var reader = server.multi_conversation.reader(client) orelse break;
        defer server.multi_conversation.discardAt(client);
        defer _ = server.per_message_arena.reset(.retain_capacity);

        messaging.handlers.process(
            server.per_message_arena.allocator(),
            &frame,
            &reader.interface,
        ) catch |err| {
            log.err("failed to process message: {t}", .{err});
            break;
        };
    }

    server.output.add(client);
    return .success;
}

fn initAt(
    server: *Server,
    index: u32,
    addr: posix.Sockaddr,
    key: messaging.Xorpad.Key,
) void {
    server.output.addUnchecked(index);

    server.cvars.packet_counters[index] = .init;
    server.cvars.addrs[index] = addr;
    server.cvars.xorpads[index].fillSeeded(key);

    server.cvars.properties.setDefaultsAt(@enumFromInt(index));
}

fn release(server: *Server, id: kcp.ConvId) bool {
    if (server.conv_map.fetchSwapRemove(id)) |kv| {
        // Release the resources associated with this `conv_id`.
        const client = kv.value;

        server.multi_conversation.destroy(client);
        return true;
    } else return false;
}

// TODO: a better name for this;
// a more or less sane structure will arise
// on its own when we'll start to track more state.
pub const ClientVariables = struct {
    packet_counters: []PacketCounter,
    xorpads: []messaging.Xorpad,
    addrs: []posix.Sockaddr,
    properties: logic.Properties,

    fn initAlloc(uninit: *ClientVariables, arena: Allocator, slots: usize) Allocator.Error!void {
        uninit.packet_counters = try arena.alloc(PacketCounter, slots);
        uninit.xorpads = try arena.alloc(messaging.Xorpad, slots);
        uninit.addrs = try arena.alloc(posix.Sockaddr, slots);
        try uninit.properties.initAlloc(arena, slots);
    }
};

pub const PacketCounter = enum(u32) {
    init = 1,
    _,

    pub fn nextId(counter: *PacketCounter) u32 {
        defer counter.* = @enumFromInt(1 +% @intFromEnum(counter.*));
        return @intFromEnum(counter.*);
    }
};

/// The list of sessions that have pending outgoing packets.
const OutputList = struct {
    head: OptionalIndex,
    nodes: []Node,

    pub fn pop(list: *OutputList) ?u32 {
        return switch (list.head) {
            .none => null,
            _ => |index| take: {
                const i = index.toInt();
                list.head = list.nodes[i].next;
                list.nodes[i].already = false;

                break :take i;
            },
        };
    }

    fn add(list: *OutputList, index: u32) void {
        if (list.nodes[index].already) return;
        list.addUnchecked(index);
    }

    fn addUnchecked(list: *OutputList, index: u32) void {
        list.nodes[index] = .{
            .next = list.head,
            .already = true,
        };

        list.head = @enumFromInt(index);
    }

    fn initAlloc(uninit: *OutputList, arena: Allocator, slots: usize) Allocator.Error!void {
        uninit.head = .none;
        uninit.nodes = try arena.alloc(Node, slots);
    }

    const Node = struct {
        const init: Node = .{ .next = .none, .already = false };

        next: OptionalIndex,
        /// Indicates if the session is already in the list.
        already: bool,
    };

    const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        fn toInt(oi: OptionalIndex) u32 {
            std.debug.assert(oi != .none);
            return @intFromEnum(oi);
        }
    };
};

const Random = std.Random;
const Allocator = std.mem.Allocator;

const heap = std.heap;
const posix = rmio.posix;
const array_hash_map = std.array_hash_map;

const kcp = @import("kcp.zig");
const logic = @import("logic.zig");
const messaging = @import("messaging.zig");

const rmio = @import("rmio");
const rmpb = @import("rmpb");

const std = @import("std");
const Server = @This();
