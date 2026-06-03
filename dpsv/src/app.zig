const log = std.log.scoped(.@"remielle-dpsv");

const accept_backlog: u31 = 100;
const buffer_size: usize = 8192;

pub fn listen(arena: Allocator, n_slots: usize, data: *const Data, address: *const posix.Sockaddr) u8 {
    var storage = Slot.Storage.initAlloc(arena, n_slots) catch
        fatal("failed to allocate {d} slots", .{n_slots});

    const listen_fd = posix.socket(
        .INET,
        .init(.STREAM, .flags(.{ .NONBLOCK = true, .CLOEXEC = true })),
        .TCP,
    ) catch |err|
        fatal("socket: {t}", .{err});

    defer posix.close(listen_fd);

    posix.setsockopt(listen_fd, .SOCKET, .REUSEADDR, 1);

    posix.bind(listen_fd, address) catch |err| switch (err) {
        error.AddressInUse => {
            log.err(
                "the address {f} is already in use; another instance of this server might be already running",
                .{address},
            );
            return 1;
        },
        else => |e| fatal("bind: {t}", .{e}),
    };

    posix.listen(listen_fd, accept_backlog) catch |err| fatal("listen: {t}", .{err});

    // Start polling on the listening socket.
    storage.pollfds[n_slots] = .{
        .fd = listen_fd,
        .events = posix.POLL.IN,
        .revents = 0,
    };

    while (true) {
        var n_events = posix.poll(storage.pollfds, -1) catch |err| fatal("poll: {t}", .{err});
        var pollfd_i: usize = 0;

        while (n_events != 0 and pollfd_i != storage.pollfds.len) : (pollfd_i += 1) {
            const pollfd = &storage.pollfds[pollfd_i];
            if (pollfd.revents == 0 or pollfd.revents == posix.POLL.NVAL) continue;
            n_events -= 1;

            if (pollfd_i == n_slots) {
                // I/O activity reported on listening socket.
                acceptAll(listen_fd, &storage, data) catch |err| switch (err) {
                    error.WouldBlock => continue, // Back to polling.
                    else => |e| {
                        log.err("acceptAll failed: {t}", .{e});
                        continue;
                    },
                };
            } else {
                // I/O activity reported on socket at `pollfd_i`, operate.
                operateAt(data, &storage, pollfd_i);
            }
        }
    }

    return 0;
}

/// Accepts all outstanding connection requests in OS queue
/// until the accept call suffers an error.
fn acceptAll(
    listen_fd: posix.socket_t,
    storage: *Slot.Storage,
    data: *const Data,
) posix.AcceptError!void {
    while (true) {
        var client_addr: posix.Sockaddr = .{ .in = std.mem.zeroes(posix.Sockaddr.In) };
        const client_fd = try posix.accept(
            listen_fd,
            &client_addr,
            .flags(.{ .CLOEXEC = true, .NONBLOCK = true }),
        );

        log.debug("new client from {f}", .{client_addr});

        const slot_index = switch (storage.free_list_head) {
            .none => evict: {
                var earliest_ns: i96 = std.math.maxInt(i96);
                var index: usize = std.math.maxInt(usize);

                for (storage.slots, 0..) |slot, i| if (slot.activity_time_ns < earliest_ns) {
                    earliest_ns = slot.activity_time_ns;
                    index = i;
                };

                log.debug("evicted connection at slot #{d}", .{index});
                posix.close(storage.slots[index].fd);

                break :evict index;
            },
            _ => |index| occupy: {
                const slot = &storage.slots[index.toInt()];
                storage.free_list_head = slot.free_list_node;
                slot.free_list_node = .none;

                break :occupy index.toInt();
            },
        };

        storage.slots[slot_index] = .{
            .fd = client_fd,
            .state = .{ .reading = .{
                .buffer = undefined,
                .end = 0,
            } },
            .activity_time_ns = 0, // Populated by `serve`
            .free_list_node = .none,
        };

        operateAt(data, storage, slot_index);
    }
}

fn operateAt(data: *const Data, storage: *Slot.Storage, slot_index: usize) void {
    const slot = &storage.slots[slot_index];

    if (serve(data, slot)) {
        // We're done
        posix.close(slot.fd);
        storage.removeAt(slot_index);
    } else |err| switch (err) {
        error.WouldBlock => {
            // Start polling on this client's socket.
            storage.pollfds[slot_index] = .{
                .fd = slot.fd,
                .events = switch (slot.state) {
                    .reading => posix.POLL.IN,
                    .writing => posix.POLL.OUT,
                },
                .revents = 0,
            };
        },
        else => |e| {
            log.err("serve failed: {t}", .{e});
            posix.close(slot.fd);
            storage.removeAt(slot_index);
        },
    }
}

fn serve(data: *const Data, slot: *Slot) !void {
    slot.activity_time_ns = posix.timespecToNs(posix.clock_gettime(.MONOTONIC) catch unreachable);

    while (true)
        switch (slot.state) {
            .reading => |*read| {
                var iov: posix.iovec = .{
                    .base = (&read.buffer).ptr[read.end..],
                    .len = @intCast(read.buffer.len - read.end),
                };

                var header: posix.msghdr = .{
                    .name = null,
                    .namelen = 0,
                    .iov = (&iov)[0..1],
                    .iovlen = 1,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };

                const n_read = try posix.recvmsg(slot.fd, &header, 0);
                if (n_read == 0)
                    // Nothing to read.
                    return;

                read.end += @truncate(n_read);

                const buffer = read.buffer[0..read.end];
                const request_line_len = std.mem.findScalar(u8, buffer, '\r') orelse continue;

                const request_line = http.RequestLine.parse(buffer[0..request_line_len]) catch |err| {
                    log.debug("failed to parse request: {t}", .{err});
                    return;
                };

                var result = routes.process(data, &request_line);

                if (!request_line.method.hasResponseBody()) {
                    result.body = null;
                }

                var iovecs: [2]posix.iovec_const = undefined;
                const count = result.toVecs(&iovecs);

                slot.state = .{ .writing = .{
                    .header = undefined,
                    .iovecs = iovecs,
                } };

                slot.state.writing.header = .{
                    .name = null,
                    .namelen = 0,
                    .iov = &slot.state.writing.iovecs,
                    .iovlen = count,
                    .control = null,
                    .controllen = 0,
                    .flags = 0,
                };
            },
            .writing => |*write| {
                const header = &write.header;
                var n_write = try posix.sendmsg(slot.fd, header, 0);

                while (n_write >= header.iov[0].len) {
                    n_write -= header.iov[0].len;
                    header.iov = header.iov[1..];
                    header.iovlen -= 1;

                    if (header.iovlen == 0)
                        // Nothing to send.
                        return;
                }

                // constCast: `header.iov` is a pointer to `write.iovecs`
                @constCast(header.iov)[0].base += @intCast(n_write);
                @constCast(header.iov)[0].len -= @intCast(n_write);
            },
        };
}

pub const Slot = struct {
    fd: posix.socket_t,
    state: State,
    activity_time_ns: i96,
    free_list_node: OptionalIndex,

    const State = union(enum) {
        reading: struct {
            buffer: [buffer_size]u8,
            end: u32,
        },
        writing: struct {
            header: posix.msghdr_const,
            iovecs: [2]posix.iovec_const,
        },
    };

    const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        fn toInt(oi: OptionalIndex) u32 {
            debug.assert(oi != .none);
            return @intFromEnum(oi);
        }
    };

    const Storage = struct {
        slots: []Slot,
        pollfds: []posix.pollfd,
        free_list_head: OptionalIndex,

        pub fn init(slots: []Slot, pollfds: []posix.pollfd) Storage {
            debug.assert(slots.len == pollfds.len - 1);

            for (slots[0 .. slots.len - 1], 1..) |*slot, i|
                slot.free_list_node = @enumFromInt(i);

            slots[slots.len - 1].free_list_node = .none;

            for (pollfds) |*pollfd| pollfd.* = .{
                .fd = posix.invalid_fd,
                .events = 0,
                .revents = 0,
            };

            return .{
                .slots = slots,
                .pollfds = pollfds,
                .free_list_head = @enumFromInt(0),
            };
        }

        pub fn initAlloc(arena: Allocator, n: usize) Allocator.Error!Storage {
            return .init(try arena.alloc(Slot, n), try arena.alloc(posix.pollfd, n + 1));
        }

        pub fn removeAt(s: *Storage, index: usize) void {
            s.pollfds[index] = .{
                .fd = posix.invalid_fd,
                .events = 0,
                .revents = 0,
            };

            s.slots[index].free_list_node = s.free_list_head;
            s.free_list_head = @enumFromInt(index);
        }
    };
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    std.process.exit(1);
}

const posix = rmio.posix;
const Allocator = std.mem.Allocator;

const debug = std.debug;

const Data = @import("Data.zig");
const http = @import("http.zig");
const routes = @import("routes.zig");

const rmio = @import("rmio");
const std = @import("std");
