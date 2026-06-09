const log = std.log.scoped(.@"remielle-gamesv");

pub fn bind(
    cancelation: *const Cancelation,
    gpa: Allocator,
    csprng: Random,
    bind_address: *const posix.Sockaddr,
    concurrent_sessions: u32,
) void {
    const server_fd = posix.socket(.INET, .init(.DGRAM, .flags(.{
        .CLOEXEC = true,
        .NONBLOCK = true,
    })), .UDP) catch |err|
        fatal("socket: {t}", .{err});

    defer posix.close(server_fd);

    posix.bind(server_fd, bind_address) catch |err| switch (err) {
        error.AddressInUse => fatal(
            "the address {f} is already in use; another instance of this server might be already running",
            .{bind_address},
        ),
        else => |e| fatal("bind: {t}", .{e}),
    };

    // Used for all of the `Server`-related persistent allocations
    var server_arena: heap.ArenaAllocator = .init(gpa);
    defer server_arena.deinit();

    // Used for temporary per-message allocations.
    var per_message_arena: heap.ArenaAllocator = .init(gpa);
    defer per_message_arena.deinit();

    var server: Server = undefined;
    server.initAlloc(server_arena.allocator(), &per_message_arena, csprng, concurrent_sessions) catch
        fatal("failed to allocate server instance for {d} sessions slots", .{concurrent_sessions});

    var server_pollfd: posix.pollfd = .{
        .fd = server_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    var buffer: [kcp.mtu]u8 = undefined;

    recvmsg: while (!cancelation.cancelRequested()) {
        var iov: [1]posix.iovec = .{.{
            .base = &buffer,
            .len = @intCast(buffer.len),
        }};

        var name: posix.Sockaddr = .{ .in = std.mem.zeroes(posix.Sockaddr.In) };

        var header: posix.msghdr = .{
            .name = name.rawMut(),
            .namelen = @sizeOf(posix.Sockaddr.In),
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        const n_recv = posix.recvmsg(server_fd, &header, 0) catch |recvmsg_err| switch (recvmsg_err) {
            // The size of packet was greater than `mtu`,
            // this should not happen for well-behaved clients.
            error.MessageOversize => continue :recvmsg,

            error.WouldBlock => poll: while (!cancelation.cancelRequested()) {
                // Poll until it becomes readable.
                _ = posix.poll((&server_pollfd)[0..1], -1) catch |poll_err| switch (poll_err) {
                    error.Interrupted => continue :poll,
                    else => |e| {
                        log.err("poll: {t}", .{e});
                        continue :poll;
                    },
                };

                if ((server_pollfd.revents & posix.POLL.IN) != 0)
                    continue :recvmsg;
            } else {
                // Canceled.
                break :recvmsg;
            },

            else => |e| {
                log.err("UDP packet receive failed: {t}", .{e});
                continue :recvmsg;
            },
        };

        const current_time = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
            error.UnsupportedClock => std.mem.zeroes(posix.timespec),
        };

        if (n_recv == kcp.Control.size) {
            var out_buf: ?[kcp.Control.size]u8 = null;
            server.receiveControlPacket(
                &name,
                .{ .buffer = buffer[0..kcp.Control.size] },
                &out_buf,
            );

            if (out_buf) |*send_buf|
                sendMessage(cancelation, server_fd, &name, send_buf) catch |err| switch (err) {
                    error.Interrupted => break :recvmsg, // The cancelation was requested.
                    else => {},
                };

            continue;
        } else if (n_recv < kcp.Header.size) continue;

        const status = server.receiveKcpPacket(
            current_time,
            &name,
            buffer[0..n_recv],
        ) catch |recv_err| switch (recv_err) {
            error.InvalidToken => {
                // This may happen if server has been restarted, but the game
                // had an active session.
                const kcp_header = kcp.Header.decode(buffer[0..kcp.Header.size]) catch unreachable;
                var ctl: [kcp.Control.size]u8 = undefined;

                kcp.Control.encode(&ctl, .disconnect, kcp_header.conv_id, kcp_header.token, 404);
                sendMessage(cancelation, server_fd, &name, &ctl) catch |send_err| switch (send_err) {
                    error.Interrupted => break :recvmsg, // The cancelation was requested.
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
                        log.err("failed to authenticate client from {f}: {t}", .{ name, e });
                        continue;
                    },
                };

                server.onAuthSucceeded(
                    server_arena.allocator(),
                    &name,
                    buffer[0..n_recv],
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
            cancelation,
            server_fd,
            current_time,
            &server.multi_conversation,
            index,
            &name,
        ) catch |err| switch (err) {
            error.Interrupted => break :recvmsg, // The cancelation was requested.
            else => {},
        };
    }

    log.info("shutting down...", .{});

    const current_time = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
        error.UnsupportedClock => std.mem.zeroes(posix.timespec),
    };

    for (server.conv_map.values()) |client_index| {
        notifyPlayerKick(
            .uncancelable, // We've already acknowledged cancelation.
            &server,
            server_fd,
            current_time,
            client_index,
            .PlayerKickReason_ServerClose,
        ) catch {};
    }
}

/// Sends `PlayerKickScNotify` followed by disconnection control packet.
fn notifyPlayerKick(
    cancelation: *const Cancelation,
    server: *Server,
    server_fd: posix.socket_t,
    current_time: posix.timespec,
    index: u32,
    reason: rmpb.main.PlayerKickReason,
) !void {
    const cmd_id = (comptime rmpb.cmdId(rmpb.main.PlayerKickScNotify)) orelse return;
    const notify: rmpb.main.PlayerKickScNotify = .{ .reason = reason };

    try messaging.sendMessage(
        &server.multi_conversation,
        &server.cvars.xorpads[index],
        index,
        .{ .packet_id = server.cvars.packet_id_counters[index] },
        cmd_id,
        notify,
    );

    try drainOutgoingPackets(
        cancelation,
        server_fd,
        current_time,
        &server.multi_conversation,
        index,
        &server.cvars.addrs[index],
    );

    var ctl: [kcp.Control.size]u8 = undefined;
    kcp.Control.encode(
        &ctl,
        .disconnect,
        server.multi_conversation.getConvIdAt(index),
        server.multi_conversation.getTokenAt(index).downgrade(),
        404,
    );

    try sendMessage(
        cancelation,
        server_fd,
        &server.cvars.addrs[index],
        &ctl,
    );
}

/// Sends all of the pending packets for the session at `index`
/// Returns `error.Interrupted` if cancelation was requested.
fn drainOutgoingPackets(
    cancelation: *const Cancelation,
    server_fd: posix.socket_t,
    current_time: posix.timespec,
    multi_conversation: *kcp.MultiConversation,
    index: u32,
    destination: *const posix.Sockaddr,
) !void {
    multi_conversation.updateAt(index, current_time);

    var output_buf: [kcp.mtu]u8 = undefined;
    var it: kcp.MultiConversation.DrainIterator = .init;

    while (!it.isAtEnd()) {
        const n_send = multi_conversation.drainAt(index, &it, &output_buf);
        if (n_send == 0) continue;

        try sendMessage(cancelation, server_fd, destination, output_buf[0..n_send]);
    }
}

/// Sends the message.
/// Returns `error.Interrupted` if cancelation was requested.
/// Blocks in case the OS send buffer is full (subject to cancelation)
fn sendMessage(
    cancelation: *const Cancelation,
    server_fd: posix.socket_t,
    to: *const posix.Sockaddr,
    data: []const u8,
) (posix.SendmsgError || error{Interrupted})!void {
    const header: posix.msghdr_const = .{
        .name = to.raw(),
        .namelen = to.len(),
        .iov = &.{.{
            .base = data.ptr,
            .len = @intCast(data.len),
        }},
        .iovlen = 1,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };

    sendmsg: while (true) if (posix.sendmsg(server_fd, &header, 0)) |_| {
        break :sendmsg;
    } else |sendmsg_err| switch (sendmsg_err) {
        error.WouldBlock => {
            // Poll until it becomes writable.
            // In case of connectionless sockets, OS buffer will be drained quickly
            // so there's no need to worry about blocking behavior here.

            var pollfd: posix.pollfd = .{
                .fd = server_fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            };

            poll: while (!cancelation.cancelRequested()) {
                _ = posix.poll((&pollfd)[0..1], -1) catch |poll_err| switch (poll_err) {
                    error.Interrupted => continue :poll,
                    else => |e| {
                        log.err("poll: {t}", .{e});
                        continue :poll;
                    },
                };

                if ((pollfd.revents & posix.POLL.OUT) != 0)
                    continue :sendmsg;
            } else {
                // Canceled.
                return error.Interrupted;
            }
        },
        else => |e| return e,
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Random = std.Random;
const Allocator = std.mem.Allocator;
const Cancelation = rmio.Cancelation;

const posix = rmio.posix;
const heap = std.heap;

const kcp = @import("kcp.zig");
const Server = @import("Server.zig");
const messaging = @import("messaging.zig");

const rmpb = @import("rmpb");
const rmio = @import("rmio");
const std = @import("std");
