const log = std.log.scoped(.@"remielle-gamesv");

multi_conversation: kcp.MultiConversation,
clients: Clients,
properties: logic.Properties.List,
conv_counter: kcp.ConvId.Counter,
/// ConvId -> session index
conv_map: array_hash_map.Auto(kcp.ConvId, u32),
/// Used for kcp tokens
conv_random: u64,
per_message_arena: *heap.ArenaAllocator,

pub const Client = struct {
    packet_counter: PacketCounter,
    xorpad: messaging.Xorpad,
    addr: net.IpAddress,
};

pub const Clients = rmmem.RemielleArrayList(rmmem.suggestBucketSize(64, Client), Client, u32);

pub const Frame = struct {
    target_index: u32,
    time: Io.Timestamp,
    clients: *Clients,
    properties: *logic.Properties.List,
    multi_conversation: *kcp.MultiConversation,

    pub inline fn player(frame: *const Frame) logic.Properties.Player {
        return @enumFromInt(frame.target_index);
    }
};

pub fn init(
    /// Used for per-message allocations
    per_message_arena: *heap.ArenaAllocator,
    csprng: Random,
) Server {
    return .{
        .multi_conversation = .init,
        .conv_counter = .init,
        .conv_map = .empty,
        .clients = .empty,
        .properties = .empty,
        .conv_random = csprng.int(u64),
        .per_message_arena = per_message_arena,
    };
}

pub fn receiveControlPacket(
    server: *Server,
    from: *const net.IpAddress,
    ctl: kcp.Control,
    out: *?[kcp.Control.size]u8,
) void {
    switch (ctl.kind()) {
        .connect => {
            const conv_id = server.conv_counter.next();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
            });

            out.* = @as([kcp.Control.size]u8, undefined);
            kcp.Control.encode(&out.*.?, .send_back_conv, conv_id, token.downgrade(), 0);
        },
        .disconnect => {
            const conv_id = ctl.conv();
            const token: kcp.Token = .init(&.{
                .random = server.conv_random,
                .conv_id = conv_id,
                .addr = @bitCast(from.ip4.bytes),
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
    from: *const net.IpAddress,
    first_packet: []u8,
    conv_id: kcp.ConvId,
    token: kcp.Token,
    current_time: Io.Timestamp,
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

    try server.conv_map.put(arena, conv_id, client);
    errdefer _ = server.conv_map.swapRemove(conv_id);

    try server.initAt(client, from.*, key);

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
    time: Io.Timestamp,
    from: *const net.IpAddress,
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
        @bitCast(from.ip4.bytes),
        kcp_header.conv_id,
    ) orelse return error.InvalidToken;

    const client = server.conv_map.get(kcp_header.conv_id) orelse
        return .{ .unauthenticated = .{ .header = kcp_header, .token = token } };

    server.multi_conversation.fillAt(client, buffer) catch
        return error.FillFailed;

    const frame: Frame = .{
        .target_index = client,
        .time = time,
        .clients = &server.clients,
        .properties = &server.properties,
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

    return .success;
}

fn initAt(
    server: *Server,
    index: u32,
    addr: net.IpAddress,
    key: messaging.Xorpad.Key,
) !void {
    if (server.clients.capacity() <= index) {
        _ = try server.clients.mapOne();
        std.debug.assert(server.clients.capacity() > index);
    }

    if (server.properties.capacity() <= index) {
        _ = try server.properties.mapOne();
        std.debug.assert(server.properties.capacity() > index);
    }

    server.clients.getPtr(.packet_counter, index).* = .init;
    server.clients.getPtr(.addr, index).* = addr;
    server.clients.getPtr(.xorpad, index).fillSeeded(key);

    logic.Properties.setDefaultsAt(&server.properties, @enumFromInt(index));
}

fn release(server: *Server, id: kcp.ConvId) bool {
    if (server.conv_map.fetchSwapRemove(id)) |kv| {
        // Release the resources associated with this `conv_id`.
        const client = kv.value;

        server.multi_conversation.destroy(client);
        return true;
    } else return false;
}

pub const PacketCounter = enum(u32) {
    init = 1,
    _,

    pub fn nextId(counter: *PacketCounter) u32 {
        defer counter.* = @enumFromInt(1 +% @intFromEnum(counter.*));
        return @intFromEnum(counter.*);
    }
};

const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const heap = std.heap;
const net = std.Io.net;
const array_hash_map = std.array_hash_map;

const kcp = @import("kcp.zig");
const logic = @import("logic.zig");
const messaging = @import("messaging.zig");

const rmio = @import("rmio");
const rmpb = @import("rmpb");
const rmmem = @import("rmmem");

const std = @import("std");
const Server = @This();
