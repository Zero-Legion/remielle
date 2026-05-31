const log = std.log.scoped(.@"remielle-dpsv");

const buffer_size: usize = 8192;
const accept_timeout: Io.Duration = .fromSeconds(1);

pub fn listen(io: Io, data: *const Data, slots: []Slot, address: net.IpAddress) u8 {
    var storage: Slot.Storage = .init(slots);

    var server = address.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.AddressInUse => {
            log.err(
                "the address {f} is already in use; another instance of this server might be already running",
                .{address},
            );
            return 1;
        },
        else => |e| {
            log.err("listen failed: {t}", .{e});
            return 1;
        },
    };

    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            => {
                io.sleep(accept_timeout, .awake) catch |sleep_err| switch (sleep_err) {
                    error.Canceled => unreachable,
                };

                continue;
            },

            error.Canceled => unreachable,

            else => |e| {
                log.err("accept failed: {t}", .{e});
                continue;
            },
        };

        // In most cases, this will be used in a single-threaded context.
        // However, we will be fallbacking to std.Io.Threaded when our Io implementation is unavailable,
        // considering a very little time window for an exclusive access, this is fine.
        while (!storage.mutex.tryLock())
            std.atomic.spinLoopHint();

        const slot_index = switch (storage.free_list_head) {
            .none => evict: {
                var earliest: Io.Timestamp = .{ .nanoseconds = std.math.maxInt(i96) };
                var index: usize = std.math.maxInt(usize);

                for (storage.slots, 0..) |slot, i| switch (slot.state) {
                    .complete => {
                        index = i;
                        break;
                    },
                    .active => if (slot.activity_time.nanoseconds < earliest.nanoseconds) {
                        earliest = slot.activity_time;
                        index = i;
                    },
                } else {
                    log.debug("evicted connection at slot #{d}", .{index});
                }

                break :evict index;
            },
            _ => |index| occupy: {
                const slot = &storage.slots[index.toInt()];
                storage.free_list_head = slot.free_list_node;
                slot.free_list_node = .none;

                break :occupy index.toInt();
            },
        };

        const slot = &storage.slots[slot_index];

        // Regardless of the way of allocation,
        // call `cancel` to free any resources associated
        // with this future.
        slot.future.cancel(io);

        storage.mutex.unlock();

        slot.* = .{
            .state = .active,
            .activity_time = .now(io, .awake),
            .free_list_node = .none,
            .future = undefined,
        };

        slot.future = io.concurrent(
            serve,
            .{ io, data, stream, &storage, slot_index },
        ) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                stream.close(io);

                // Back to the free list

                while (!storage.mutex.tryLock()) {}
                defer storage.mutex.unlock();

                slot.free_list_node = storage.free_list_head;
                storage.free_list_head = @enumFromInt(slot_index);

                continue;
            },
        };
    }

    return 0;
}

fn serve(
    io: Io,
    data: *const Data,
    stream: net.Stream,
    storage: *Slot.Storage,
    index: usize,
) void {
    const slot = &storage.slots[index];
    defer stream.close(io);

    log.debug("new connection from {f}", .{stream.socket.address});
    defer log.debug("client from {f} disconnected", .{stream.socket.address});

    defer recycle: {
        // Put our slot to the free list

        io.checkCancel() catch
            // This function is exitting due to cancelation,
            // we don't have to put ourselves to the free_list
            // because the accept loop has already reclaimed this slot.
            break :recycle;

        slot.state = .complete;

        while (!storage.mutex.tryLock()) {
            std.atomic.spinLoopHint();
            io.checkCancel() catch {
                // We've got canceled while waiting for a lock.
                // This means that the accept loop has evicted this connection,
                // although we're already done, we weren't fast enough to
                // put ourselves into the free list. In this case, it doesn't matter anymore.
                break :recycle;
            };
        }

        defer storage.mutex.unlock();

        slot.free_list_node = storage.free_list_head;
        storage.free_list_head = @enumFromInt(@as(u32, @intCast(index)));
    }

    var recv_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);

    const request_line_raw = reader.interface.takeDelimiterInclusive('\r') catch |err| switch (err) {
        error.EndOfStream, error.StreamTooLong => return,
        error.ReadFailed => switch (reader.err.?) {
            error.Canceled => {
                io.recancel();
                return;
            },
            else => return,
        },
    };

    const request_line = http.RequestLine.parse(request_line_raw) catch |err| {
        log.debug("failed to parse request from {f}: {t}", .{ stream.socket.address, err });
        return;
    };

    var result = routes.process(data, &request_line);

    if (!request_line.method.hasResponseBody()) {
        result.body = null;
    }

    var vecs_buffer: [2][]const u8 = undefined;
    const vecs = result.toVecs(&vecs_buffer);

    // We're at "sending" state at this point, block the cancelation.
    // The `send` operation should complete instantly, unless zerocopy is used.
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    slot.activity_time = .now(io, .awake);

    var writer = stream.writer(io, &.{});
    writer.interface.writeVecAll(vecs) catch {};
}

pub const Slot = struct {
    state: State,
    activity_time: Io.Timestamp,
    future: Io.Future(void),
    free_list_node: OptionalIndex,

    const State = enum(u1) {
        active,
        complete,
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
        mutex: std.atomic.Mutex,
        slots: []Slot,
        free_list_head: OptionalIndex,

        pub fn init(slots: []Slot) Storage {
            for (slots[0 .. slots.len - 1], 1..) |*slot, i| {
                slot.free_list_node = @enumFromInt(i);
                slot.future.any_future = null; // `cancel` will return immediately
            }

            slots[slots.len - 1].free_list_node = .none;
            slots[slots.len - 1].future.any_future = null;

            return .{
                .mutex = .unlocked,
                .slots = slots,
                .free_list_head = @enumFromInt(0),
            };
        }
    };
};

const Io = std.Io;
const Allocator = std.mem.Allocator;

const net = std.Io.net;
const debug = std.debug;

const Data = @import("Data.zig");
const http = @import("http.zig");
const routes = @import("routes.zig");

const std = @import("std");
