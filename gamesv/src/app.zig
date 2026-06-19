const log = std.log.scoped(.@"remielle-gamesv");

pub fn bind(
    io: Io,
    gpa: Allocator,
    csprng: Random,
    udp_address: *const net.IpAddress,
    concurrent_sessions: u32,
) Io.Cancelable!void {
    const udp_socket = udp_address.bind(
        io,
        .{ .mode = .dgram, .protocol = .udp },
    ) catch |err| switch (err) {
        error.AddressInUse => fatal(
            "the address {f} is already in use; another instance of this server might be already running",
            .{udp_address},
        ),
        else => |e| fatal("bind: {t}", .{e}),
    };

    defer udp_socket.close(io);

    // Used for all of the `Server`-related persistent allocations
    var server_arena: heap.ArenaAllocator = .init(gpa);
    defer server_arena.deinit();

    // Used for temporary per-message allocations.
    var per_message_arena: heap.ArenaAllocator = .init(gpa);
    defer per_message_arena.deinit();

    var server: Server = undefined;
    server.initAlloc(server_arena.allocator(), &per_message_arena, csprng, concurrent_sessions) catch
        fatal("failed to allocate server instance for {d} sessions slots", .{concurrent_sessions});

    var buffer: [kcp.mtu]u8 = undefined;

    recv_loop: while (true) {
        const udp_message = udp_socket.receive(io, &buffer) catch |err| switch (err) {
            // The size of packet was greater than `mtu`,
            // this should not happen for well-behaved clients.
            error.MessageOversize => continue :recv_loop,

            error.Canceled => break :recv_loop,

            else => |e| {
                log.err("UDP packet receive failed: {t}", .{e});
                continue :recv_loop;
            },
        };

        const current_time: Io.Timestamp = .now(io, .real);

        if (udp_message.data.len == kcp.Control.size) {
            var out_buf: ?[kcp.Control.size]u8 = null;
            server.receiveControlPacket(
                &udp_message.from,
                .{ .buffer = buffer[0..kcp.Control.size] },
                &out_buf,
            );

            if (out_buf) |*send_buf|
                udp_socket.send(io, &udp_message.from, send_buf) catch |err| switch (err) {
                    error.Canceled => |e| return e,
                    else => {},
                };

            continue;
        } else if (udp_message.data.len < kcp.Header.size) continue;

        const status = server.receiveKcpPacket(
            current_time,
            &udp_message.from,
            udp_message.data,
        ) catch |recv_err| switch (recv_err) {
            error.InvalidToken => {
                // This may happen if server has been restarted, but the game
                // had an active session.
                const kcp_header = kcp.Header.decode(buffer[0..kcp.Header.size]) catch unreachable;
                var ctl: [kcp.Control.size]u8 = undefined;

                kcp.Control.encode(&ctl, .disconnect, kcp_header.conv_id, kcp_header.token, 404);
                udp_socket.send(io, &udp_message.from, &ctl) catch |send_err| switch (send_err) {
                    error.Canceled => |e| return e,
                    else => {},
                };

                continue;
            },
            error.MalformedPacket, error.FillFailed => continue,
        };

        switch (status) {
            .success => {},
            .unauthenticated => |input| {
                var request_string_buffer: [1024]u8 = undefined;

                const request = messaging.expectFirstPacket(
                    &request_string_buffer,
                    buffer[kcp.Header.size..][0..input.header.len],
                ) catch |err| switch (err) {
                    error.SizeMismatch,
                    error.InvalidMagic,
                    error.UnexpectedCmdId,
                    error.MalformedPayload,
                    => continue,
                };

                var response_string_buffer: [messaging.auth.string_buffer_size]u8 = undefined;

                const player_token = messaging.auth.playerGetToken(
                    csprng,
                    &request,
                    &response_string_buffer,
                ) catch |err| switch (err) {
                    error.RandKeyDecryptFail => |e| {
                        log.err("failed to authenticate client from {f}: {t}", .{ udp_message.from, e });
                        continue;
                    },
                };

                server.onAuthSucceeded(
                    server_arena.allocator(),
                    &udp_message.from,
                    udp_message.data,
                    input.header.conv_id,
                    input.token,
                    current_time,
                    player_token.key,
                    player_token.response,
                ) catch |err| switch (err) {
                    error.MessageOversize,
                    error.OutOfMemory,
                    error.SessionLimitExceeded,
                    error.InvalidFirstPacket,
                    => continue,
                };
            },
        }

        while (server.output.pop()) |index| drainOutgoingPackets(
            io,
            udp_socket,
            current_time,
            &server.multi_conversation,
            index,
            &udp_message.from,
        ) catch |err| switch (err) {
            error.Canceled => break :recv_loop, // The cancelation was requested.
            else => {},
        };
    }

    log.info("shutting down...", .{});

    if (rmpb.features.isAvailable(.player_kick)) {
        const current_time: Io.Timestamp = .now(io, .real);

        for (server.conv_map.values()) |client_index| {
            notifyPlayerKick(
                io,
                udp_socket,
                &server,
                current_time,
                client_index,
                .PlayerKickReason_ServerClose,
            ) catch {};
        }
    }
}

/// Sends `PlayerKickScNotify` followed by disconnection control packet.
fn notifyPlayerKick(
    io: Io,
    udp_socket: net.Socket,
    server: *Server,
    current_time: Io.Timestamp,
    index: u32,
    reason: rmpb.main.PlayerKickReason,
) !void {
    const notify: rmpb.main.PlayerKickScNotify = .{ .reason = reason };

    try messaging.send(
        &server.multi_conversation,
        &server.cvars,
        index,
        .notify,
        notify,
    );

    try drainOutgoingPackets(
        io,
        udp_socket,
        current_time,
        &server.multi_conversation,
        index,
        &server.cvars.addrs[index],
    );

    var ctl: [kcp.Control.size]u8 = undefined;
    const identifier = server.multi_conversation.identifierAt(index);

    kcp.Control.encode(
        &ctl,
        .disconnect,
        identifier.id,
        identifier.token.downgrade(),
        404,
    );

    try udp_socket.send(io, &server.cvars.addrs[index], &ctl);
}

fn drainOutgoingPackets(
    io: Io,
    udp_socket: net.Socket,
    current_time: Io.Timestamp,
    multi_conversation: *kcp.MultiConversation,
    index: u32,
    destination: *const net.IpAddress,
) !void {
    multi_conversation.updateAt(index, current_time);

    var output_buf: [kcp.mtu]u8 = undefined;
    var it: kcp.MultiConversation.DrainIterator = .init;

    while (!it.isAtEnd()) {
        const n_send = multi_conversation.drainAt(index, &it, &output_buf);
        if (n_send == 0) continue;

        try udp_socket.send(io, destination, output_buf[0..n_send]);
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Io = std.Io;
const Random = std.Random;
const Allocator = std.mem.Allocator;

const heap = std.heap;
const net = std.Io.net;

const kcp = @import("kcp.zig");
const Server = @import("Server.zig");
const messaging = @import("messaging.zig");

const rmpb = @import("rmpb");
const rmio = @import("rmio");
const std = @import("std");
