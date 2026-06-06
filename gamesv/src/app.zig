const log = std.log.scoped(.@"hollowell-gamesv");

pub fn bind(gpa: Allocator, csprng: Random, bind_address: *const posix.Sockaddr) u8 {
    const server_fd = posix.socket(.INET, .init(.DGRAM, .flags(.{ .CLOEXEC = true })), .UDP) catch |err|
        fatal("socket: {t}", .{err});

    defer posix.close(server_fd);

    posix.bind(server_fd, bind_address) catch |err| switch (err) {
        error.AddressInUse => {
            log.err(
                "the address {f} is already in use; another instance of this server might be already running",
                .{bind_address},
            );
            return 1;
        },
        else => |e| fatal("bind: {t}", .{e}),
    };

    // Used for all of the `Server`-related persistent allocations
    var server_arena: heap.ArenaAllocator = .init(gpa);
    defer server_arena.deinit();

    // Used for temporary per-message allocations.
    var per_message_arena: heap.ArenaAllocator = .init(gpa);
    defer per_message_arena.deinit();

    const slots: usize = 16; // TODO: make it an option
    var server: Server = undefined;
    server.initAlloc(server_arena.allocator(), &per_message_arena, csprng, slots) catch
        fatal("failed to allocate server instance for {d} sessions slots", .{slots});

    while (true) {
        var buffer: [kcp.mtu]u8 = undefined;

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

        const n_recv = posix.recvmsg(server_fd, &header, 0) catch |err| switch (err) {
            // The size of packet was greater than `mtu`,
            // this should not happen for well-behaved clients.
            error.MessageOversize => continue,

            else => |e| {
                log.err("UDP packet receive failed: {t}", .{e});
                continue;
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

            if (out_buf) |*send_buf| {
                const ctl_header: posix.msghdr_const = .{
                    .name = header.name,
                    .namelen = header.namelen,
                    .iov = &.{.{
                        .base = send_buf,
                        .len = @intCast(kcp.Control.size),
                    }},
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                _ = posix.sendmsg(server_fd, &ctl_header, 0) catch |err| switch (err) {
                    error.MessageOversize => unreachable,
                    else => continue,
                };
            }

            continue;
        } else if (n_recv < kcp.Header.size) continue;

        const status = server.receiveKcpPacket(
            current_time,
            &name,
            buffer[0..n_recv],
        ) catch |err| switch (err) {
            error.InvalidToken => {
                // This may happen if server has been restarted, but the game
                // had an active session.

                const kcp_header = kcp.Header.decode(buffer[0..kcp.Header.size]) catch unreachable;
                var ctl: [kcp.Control.size]u8 = undefined;
                kcp.Control.encode(&ctl, .disconnect, kcp_header.conv_id, kcp_header.token, 404);

                const ctl_header: posix.msghdr_const = .{
                    .name = header.name,
                    .namelen = header.namelen,
                    .iov = &.{.{
                        .base = &ctl,
                        .len = @intCast(kcp.Control.size),
                    }},
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                _ = posix.sendmsg(server_fd, &ctl_header, 0) catch |send_err| switch (send_err) {
                    error.MessageOversize => unreachable,
                    else => continue,
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
            server_fd,
            current_time,
            &server.multi_conversation,
            index,
            &name,
        ) catch |err| switch (err) {
            else => {},
        };
    }

    return 0;
}

fn drainOutgoingPackets(
    server_fd: posix.socket_t,
    current_time: posix.timespec,
    multi_conversation: *kcp.MultiConversation,
    client: u32,
    destination: *const posix.Sockaddr,
) !void {
    multi_conversation.updateAt(client, current_time);

    var output: [kcp.mtu]u8 = undefined;
    var it: kcp.MultiConversation.DrainIterator = .init;

    while (!it.isAtEnd()) {
        const n_send = multi_conversation.drainAt(client, &it, &output);
        if (n_send == 0) continue;

        const header: posix.msghdr_const = .{
            .name = destination.raw(),
            .namelen = destination.len(),
            .iov = &.{.{
                .base = &output,
                .len = @intCast(n_send),
            }},
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };

        _ = try posix.sendmsg(server_fd, &header, 0);
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const Random = std.Random;
const Allocator = std.mem.Allocator;

const posix = nrmio.posix;
const heap = std.heap;

const kcp = @import("kcp.zig");
const Server = @import("Server.zig");
const messaging = @import("messaging.zig");

const nrmio = @import("nrmio");
const std = @import("std");
