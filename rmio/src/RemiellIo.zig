//! Deprecated. Use `rmio.posix` instead.

impl: Impl,
arena: std.heap.ArenaAllocator,
coro_storage: Coroutine.Storage,
current_coro: Coroutine.OptionalIndex,
naked_wait: WaitPoint,
csprng: ?DefaultCsprng,

pub const Impl = switch (native_os) {
    .linux => @import("RemiellIo/Uring.zig"),
    .windows => @import("RemiellIo/Iocp.zig"),
    else => |os_tag| @compileError("Unsupported OS " ++ @tagName(os_tag)),
};

pub const supported = switch (native_os) {
    .linux,
    .windows,
    => true,

    else => false,
};

pub const InitOptions = struct {
    coroutines: u32,
    stack_size: usize,
};

const WaitPoint = struct {
    awaitee: Awaitee,
    context: Io.fiber.Context,

    const Awaitee = union(enum) {
        /// The coroutine is not waiting on anything.
        none: void,
        /// The coroutine has finished and is now in an idle state.
        idle: void,
        /// The coroutine is waiting for an I/O operation to complete.
        operation: struct {
            /// How many of those below are pending
            outstanding: u2,

            primary: Operation.Storage.Tagged,
            cancelation: Operation.Storage.Tagged,
        },
        /// The coroutine is waiting for another coroutine to exit.
        coroutine: struct {
            /// Index into `Coroutine.Storage.items`
            index: u32,
        },

        pub fn ready(awaitee: *const Awaitee, rio: *RemiellIo) bool {
            return switch (awaitee.*) {
                .none => true,
                .idle => false,
                .operation => |operation| operation.outstanding == 0,
                .coroutine => |child| rio.coro_storage.items[child.index].state == .finished,
            };
        }
    };

    pub fn submit(wp: *WaitPoint, operation: Operation, rio: *RemiellIo) void {
        wp.awaitee = .{
            .operation = .{
                .outstanding = 1,
                .primary = .{
                    .tag = 0, // Primary
                    .storage = .init(operation),
                },
                .cancelation = .{
                    .tag = 1, // Cancelation
                    .storage = undefined, // Populated by `cancel`.
                },
            },
        };

        rio.impl.submissions.append(&wp.awaitee.operation.primary.storage.submission.node);
    }
};

pub const InitError = error{
    SystemResources,
    /// The I/O implementation is not supported.
    Unsupported,
} || Allocator.Error || Io.UnexpectedError;

pub fn init(gpa: Allocator, options: InitOptions) InitError!RemiellIo {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();

    const coroutines = try arena.allocator().alloc(Coroutine, options.coroutines);
    const storage: Coroutine.Storage = try .init(coroutines, options.stack_size, arena.allocator());

    return .{
        .impl = try .init(),
        .arena = arena,
        .coro_storage = storage,
        .current_coro = .none,
        .naked_wait = .{ .awaitee = .none, .context = undefined },
        .csprng = null,
    };
}

pub fn deinit(rio: *RemiellIo) void {
    rio.impl.deinit();
    rio.arena.deinit();
}

const Coroutine = struct {
    buffer: []u8,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    result_ptr: *anyopaque,
    context_ptr: *const anyopaque,
    state: State,
    cancel_protection: Io.CancelProtection,
    list_node: OptionalIndex,
    wait_point: WaitPoint,
    rio: *RemiellIo,
    awaiter: ?Awaiter,

    const State = enum(u2) {
        running = 0b00,
        finished = 0b01,
        cancel_requested = 0b10,
        cancel_acknowledged = 0b11,
    };

    const Awaiter = union(enum) {
        naked: *Io.fiber.Context,
        coroutine: *Coroutine,
    };

    const Storage = struct {
        items: []Coroutine,
        // Unused coroutine slots.
        free_list_head: OptionalIndex,
        // Queued to run coroutines on the next yield.
        queued_list_head: OptionalIndex,

        pub fn init(
            items: []Coroutine,
            stack_size: usize,
            stack_allocator: Allocator,
        ) Allocator.Error!Storage {
            for (items[0 .. items.len - 1], 1..) |*item, i| {
                item.list_node = @enumFromInt(i);
                item.buffer = try stack_allocator.alloc(u8, stack_size);
            }

            items[items.len - 1].list_node = .none;
            items[items.len - 1].buffer = try stack_allocator.alloc(u8, stack_size);

            return .{
                .items = items,
                .free_list_head = @enumFromInt(0),
                .queued_list_head = .none,
            };
        }

        pub fn schedule(coro_storage: *Storage, coro: *Coroutine) void {
            coro.list_node = coro_storage.queued_list_head;
            coro_storage.queued_list_head = @enumFromInt(coro_storage.indexOf(coro));
        }

        pub fn recycle(coro_storage: *Storage, coro: *Coroutine) void {
            coro.list_node = coro_storage.queued_list_head;
            coro_storage.free_list_head = @enumFromInt(coro_storage.indexOf(coro));
        }

        pub fn indexOf(coro_storage: *Storage, coro: *const Coroutine) u32 {
            return @intCast(@divExact(
                @intFromPtr(coro) - @intFromPtr(coro_storage.items.ptr),
                @sizeOf(Coroutine),
            ));
        }
    };

    const OptionalIndex = enum(u32) {
        none = std.math.maxInt(u32),
        _,

        fn toInt(oi: OptionalIndex) u32 {
            debug.assert(oi != .none);
            return @intFromEnum(oi);
        }
    };
};

const vtable: Io.VTable = vtable: {
    var v = Io.failing.vtable.*;

    v.operate = operate;
    v.concurrent = concurrent;
    v.cancel = cancel;
    v.recancel = recancel;
    v.checkCancel = checkCancelErased;
    v.swapCancelProtection = swapCancelProtection;
    v.netBindIp = netBindIp;
    v.netSend = netSend;
    v.netListenIp = netListenIp;
    v.netClose = netClose;
    v.netAccept = netAccept;
    v.netRead = netRead;
    v.netWrite = netWrite;
    v.now = now;
    v.random = random;
    v.randomSecure = randomSecure;

    break :vtable v;
};

pub fn io(rio: *RemiellIo) Io {
    return .{ .userdata = rio, .vtable = &vtable };
}

fn operate(userdata: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    try rio.checkCancel();

    switch (operation) {
        .net_receive => |*o| {
            if (o.message_buffer.len == 0)
                return .{ .net_receive = .{ null, 0 } };

            const message = &o.message_buffer[0];

            const point = rio.waitPoint();
            point.submit(.{ .net_receive = .{
                .socket_handle = o.socket_handle,
                .from = &message.from,
                .buffer = o.data_buffer,
            } }, rio);

            rio.block(.submission);

            const bytes_received = rio.unblock(
                point.awaitee.operation.primary.storage.completion.result.net_receive,
            ) catch |err| switch (err) {
                error.Canceled => |e| return e,
                else => |e| return .{ .net_receive = .{ e, 0 } },
            };

            message.data = o.data_buffer[0..bytes_received];

            return .{ .net_receive = .{ null, 1 } };
        },

        .file_read_streaming, .file_write_streaming => @panic("TODO: implement file I/O"),
        .device_io_control => @panic("`device_io_control` is not supported"),
    }
}

fn concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: std.mem.Alignment,
    context: []const u8,
    context_alignment: std.mem.Alignment,
    start: *const fn (context: *const anyopaque, result: *anyopaque) void,
) Io.ConcurrentError!*Io.AnyFuture {
    const inner = struct {
        fn entry() callconv(.naked) void {
            switch (builtin.cpu.arch) {
                .x86_64 => switch (native_os) {
                    .windows => asm volatile (
                        \\ subq $40, %%rsp
                        \\ movq 40(%%rsp), %%rcx
                        \\ jmp %[call:P]
                        :
                        : [call] "X" (&call),
                    ),
                    else => asm volatile (
                        \\ subq $40, %%rsp
                        \\ movq 40(%%rsp), %%rdi
                        \\ jmp %[call:P]
                        :
                        : [call] "X" (&call),
                    ),
                },
                else => |arch| @compileError("unimplemented architecture: " ++ @tagName(arch)),
            }
        }

        fn call(coro: *Coroutine) callconv(.c) noreturn {
            coro.start(coro.context_ptr, coro.result_ptr);
            coro.state = .finished;
            const rio = coro.rio;

            if (coro.awaiter) |awaiter| {
                const awaiter_context = context: switch (awaiter) {
                    .naked => {
                        rio.current_coro = .none;
                        break :context &rio.naked_wait.context;
                    },
                    .coroutine => |other| {
                        rio.current_coro = @enumFromInt(rio.coro_storage.indexOf(other));
                        break :context &other.wait_point.context;
                    },
                };

                _ = Io.fiber.contextSwitch(&.{
                    .old = &coro.wait_point.context,
                    .new = awaiter_context,
                });
            } else rio.block(.idle);

            unreachable;
        }
    };

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    const coro_index = switch (rio.coro_storage.free_list_head) {
        .none => return error.ConcurrencyUnavailable,
        _ => |index| index.toInt(),
    };

    const coro = &rio.coro_storage.items[coro_index];
    rio.coro_storage.free_list_head = coro.list_node;
    coro.list_node = .none;

    const buf_aligned = result_alignment.forward(@intFromPtr(coro.buffer.ptr));
    const owned_context_ptr: [*]u8 = @ptrFromInt(context_alignment.forward(buf_aligned + result_len));

    // The bare minimum of buffer size. Of course, we'll also need some for the stack itself.
    const aligned_end = @intFromPtr(owned_context_ptr) + context.len;

    // This is where actual coroutine stack starts.
    const stack_start: [*]u8 = @ptrFromInt(std.mem.alignForward(usize, aligned_end, 16));
    const stack_pointer: [*]u8 = @ptrFromInt(std.mem.alignBackward(
        usize,
        @intFromPtr(coro.buffer.ptr) + coro.buffer.len - 8,
        16,
    ));

    if (@intFromPtr(stack_start) - @intFromPtr(coro.buffer.ptr) > coro.buffer.len)
        return error.ConcurrencyUnavailable;

    coro.start = start;
    coro.result_ptr = @ptrFromInt(buf_aligned);
    coro.context_ptr = owned_context_ptr;
    coro.state = .running;
    coro.cancel_protection = .unblocked;
    coro.rio = rio;
    coro.awaiter = null;

    coro.wait_point = .{ .awaitee = .none, .context = .{
        .rsp = @intFromPtr(stack_pointer),
        .rip = @intFromPtr(&inner.entry),
        .rbp = 0,
    } };

    @memcpy(owned_context_ptr[0..context.len], context);
    @memcpy(stack_pointer[0..8], std.mem.asBytes(&coro));

    rio.coro_storage.schedule(coro);
    return @ptrCast(coro);
}

fn cancel(
    userdata: ?*anyopaque,
    any_future: *Io.AnyFuture,
    result: []u8,
    result_alignment: std.mem.Alignment,
) void {
    _ = result_alignment;

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    const coroutine: *Coroutine = @ptrCast(@alignCast(any_future));

    switch (coroutine.state) {
        .running => {
            coroutine.state = .cancel_requested;

            coroutine.awaiter = switch (rio.current_coro) {
                .none => .{ .naked = &rio.naked_wait.context },
                _ => |index| .{ .coroutine = &rio.coro_storage.items[index.toInt()] },
            };

            const cancel_index: Coroutine.OptionalIndex = @enumFromInt(rio.coro_storage.indexOf(coroutine));

            switch (coroutine.wait_point.awaitee) {
                .operation => |*o| {
                    o.outstanding += 1;
                    o.cancelation.storage = .init(.{ .cancel = .{
                        .operation = &o.primary.storage,
                    } });

                    rio.impl.submissions.append(&o.cancelation.storage.submission.node);
                },
                else => {},
            }

            rio.block(.{ .await = cancel_index.toInt() });
        },
        .finished => {}, // Nothing to do
        .cancel_requested, .cancel_acknowledged => unreachable, // always a race condition
    }

    rio.coro_storage.recycle(coroutine);
    @memcpy(result, @as([*]u8, @ptrCast(coroutine.result_ptr))[0..result.len]);
}

fn recancel(userdata: ?*anyopaque) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    switch (rio.current_coro) {
        // This is unreachable because first of all main frame cannot be canceled,
        // second of all, recancel() may only be called to re-arm cancelation request
        .none => unreachable,

        _ => |index| {
            const coro = &rio.coro_storage.items[index.toInt()];
            switch (coro.state) {
                .running, .finished, .cancel_requested => unreachable,
                .cancel_acknowledged => coro.state = .cancel_requested,
            }
        },
    }
}

fn netClose(userdata: ?*anyopaque, handles: []const net.Socket.Handle) void {
    _ = userdata;
    for (handles) |socket| switch (native_os) {
        .windows => _ = Impl.closesocket(socket),
        else => _ = std.posix.system.close(socket),
    };
}

fn netBindIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.BindOptions,
) net.IpAddress.BindError!net.Socket {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return rio.impl.netBind(address, options, false);
}

fn netSend(userdata: ?*anyopaque, socket_handle: net.Socket.Handle, messages: []net.OutgoingMessage, flags: net.SendFlags) struct { ?net.Socket.SendError, usize } {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    rio.checkCancel() catch |err|
        return .{ err, 0 };

    for (messages, 0..) |*message, sent|
        rio.netSendOne(socket_handle, message, flags) catch |err|
            return .{ err, sent };

    return .{ null, messages.len };
}

fn netSendOne(
    rio: *RemiellIo,
    socket_handle: net.Socket.Handle,
    message: *net.OutgoingMessage,
    flags: net.SendFlags,
) net.Socket.SendError!void {
    _ = flags;

    const point = rio.waitPoint();
    point.submit(.{ .net_send = .{
        .socket_handle = socket_handle,
        .to = message.address,
        .buffer = message.data_ptr[0..message.data_len],
    } }, rio);

    rio.block(.submission);

    if (rio.unblock(point.awaitee.operation.primary.storage.completion.result.net_send)) |n_sent|
        message.data_len = n_sent
    else |err| {
        message.data_len = 0;
        return err;
    }
}

fn netListenIp(
    userdata: ?*anyopaque,
    address: *const net.IpAddress,
    options: net.IpAddress.ListenOptions,
) net.IpAddress.ListenError!net.Socket {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return rio.impl.netListen(address, options);
}

fn netAccept(
    userdata: ?*anyopaque,
    listener: net.Socket.Handle,
    options: net.Server.AcceptOptions,
) net.Server.AcceptError!net.Socket {
    _ = options;

    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    try rio.checkCancel();

    const point = rio.waitPoint();
    point.submit(.{ .net_accept = .{
        .listener_handle = listener,
    } }, rio);

    rio.block(.submission);
    return rio.unblock(point.awaitee.operation.primary.storage.completion.result.net_accept);
}

fn netRead(
    userdata: ?*anyopaque,
    socket: net.Socket.Handle,
    data: [][]u8,
) net.Stream.Reader.Error!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    try rio.checkCancel();

    const point = rio.waitPoint();
    point.submit(.{ .net_read = .{
        .stream_handle = socket,
        .buffer = data[0],
    } }, rio);

    rio.block(.submission);
    return rio.unblock(point.awaitee.operation.primary.storage.completion.result.net_read);
}

fn netWrite(
    userdata: ?*anyopaque,
    socket: net.Socket.Handle,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) net.Stream.Writer.Error!usize {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    try rio.checkCancel();

    var iovecs: [8]Impl.Vector(.@"const") = undefined;
    var iovecs_count: usize = 0;

    addVector(.@"const", &iovecs, &iovecs_count, header);
    for (data[0 .. data.len - 1]) |bytes| addVector(.@"const", &iovecs, &iovecs_count, bytes);
    const pattern = data[data.len - 1];

    var splat_backup_buffer: [64]u8 = undefined;
    if (iovecs.len - iovecs_count != 0) switch (splat) {
        0 => {},
        1 => addVector(.@"const", &iovecs, &iovecs_count, pattern),
        else => switch (pattern.len) {
            0 => {},
            1 => {
                const splat_buffer = &splat_backup_buffer;
                const memset_len = @min(splat_buffer.len, splat);
                const buf = splat_buffer[0..memset_len];
                @memset(buf, pattern[0]);
                addVector(.@"const", &iovecs, &iovecs_count, buf);
                var remaining_splat = splat - buf.len;
                while (remaining_splat > splat_buffer.len and iovecs.len - iovecs_count != 0) {
                    debug.assert(buf.len == splat_buffer.len);
                    addVector(.@"const", &iovecs, &iovecs_count, splat_buffer);
                    remaining_splat -= splat_buffer.len;
                }
                addVector(.@"const", &iovecs, &iovecs_count, splat_buffer[0..@min(remaining_splat, splat_buffer.len)]);
            },
            else => for (0..@min(splat, iovecs.len - iovecs_count)) |_| {
                addVector(.@"const", &iovecs, &iovecs_count, pattern);
            },
        },
    };

    const point = rio.waitPoint();
    point.submit(.{ .net_write = .{
        .stream_handle = socket,
        .data = iovecs[0..iovecs_count],
    } }, rio);

    rio.block(.submission);
    return rio.unblock(point.awaitee.operation.primary.storage.completion.result.net_write);
}

fn random(userdata: ?*anyopaque, buffer: []u8) void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));

    if (rio.csprng == null) {
        @branchHint(.unlikely);
        var seed: [DefaultCsprng.secret_seed_length]u8 = undefined;

        randomSecureFill(&seed) catch {
            // Fallback seed
            std.mem.writeInt(u64, buffer[0..8], @intCast(Impl.getTime(.boot).toMilliseconds()), .native);
            std.mem.writeInt(usize, buffer[8..][0..@sizeOf(usize)], @intFromPtr(userdata), .native);
        };

        rio.csprng = .init(seed);
    }

    rio.csprng.?.fill(buffer);
}

fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    try rio.checkCancel();
    try randomSecureFill(buffer);
}

fn randomSecureFill(buffer: []u8) !void {
    // Right now it's synchronous.
    switch (native_os) {
        .linux => fillFromDevUrandom(buffer) catch
            return error.EntropyUnavailable,
        .windows => fillFromDeviceCng(buffer) catch
            return error.EntropyUnavailable,
        else => return error.EntropyUnavailable, // Not implemented.
    }
}

fn fillFromDevUrandom(buffer: []u8) !void {
    const open_rc = linux.open("/dev/urandom", .{}, 0);
    const fd: linux.fd_t = switch (linux.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.OpenFailed,
    };

    defer _ = linux.close(fd);

    var unfilled = buffer;
    while (unfilled.len != 0) {
        const read_rc = linux.read(fd, unfilled.ptr, unfilled.len);
        switch (linux.errno(read_rc)) {
            .SUCCESS => unfilled = unfilled[read_rc..],
            else => return error.ReadFailed,
        }
    }
}

fn fillFromDeviceCng(buffer: []u8) !void {
    var handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtOpenFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .FILE = .{ .READ_DATA = true } },
        },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(
            &.{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'C', 'N', 'G' },
        )) },
        &iosb,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => {},
        else => return error.OpenFailed,
    }

    defer _ = windows.ntdll.NtClose(handle);

    var unfilled = buffer;
    while (unfilled.len != 0) switch (windows.ntdll.NtDeviceIoControlFile(
        handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.KSEC.GEN_RANDOM,
        null,
        0,
        unfilled.ptr,
        @truncate(unfilled.len),
    )) {
        .SUCCESS => unfilled = unfilled[@as(u32, @truncate(unfilled.len))..],
        else => return error.IoctlFailed,
    };
}

fn checkCancelErased(userdata: ?*anyopaque) Io.Cancelable!void {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return rio.checkCancel();
}

fn checkCancel(rio: *RemiellIo) Io.Cancelable!void {
    switch (rio.current_coro) {
        .none => return,
        _ => |index| {
            const coro = &rio.coro_storage.items[index.toInt()];
            switch (coro.state) {
                .cancel_requested => switch (coro.cancel_protection) {
                    .blocked => {},
                    .unblocked => {
                        coro.state = .cancel_acknowledged;
                        return error.Canceled;
                    },
                },
                .cancel_acknowledged, .running => {},
                .finished => unreachable,
            }
        },
    }
}

fn unblock(rio: *RemiellIo, result: anytype) @TypeOf(result) {
    _ = result catch |err| switch (err) {
        error.Canceled => {
            const coro = &rio.coro_storage.items[rio.current_coro.toInt()];
            debug.assert(coro.state == .cancel_requested);
            coro.state = .cancel_acknowledged;
        },
        else => {},
    };

    return result;
}

fn swapCancelProtection(userdata: ?*anyopaque, protection: Io.CancelProtection) Io.CancelProtection {
    const rio: *RemiellIo = @ptrCast(@alignCast(userdata));
    return switch (rio.current_coro) {
        .none => .unblocked,
        _ => |index| swap: {
            const coro = &rio.coro_storage.items[index.toInt()];
            const old_cancel_protection = coro.cancel_protection;
            coro.cancel_protection = protection;
            break :swap old_cancel_protection;
        },
    };
}

fn now(userdata: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    _ = userdata;

    return switch (clock) {
        .real, .awake, .boot, .cpu_process => Impl.getTime(clock),
        .cpu_thread => .zero, // TODO: this has to respect coroutines
    };
}

fn waitPoint(rio: *RemiellIo) *WaitPoint {
    return switch (rio.current_coro) {
        .none => &rio.naked_wait,
        _ => |index| &rio.coro_storage.items[index.toInt()].wait_point,
    };
}

const WaitReason = union(enum) {
    idle,
    submission,
    await: u32,
};

fn block(rio: *RemiellIo, reason: WaitReason) void {
    const enter_wait_point = switch (rio.current_coro) {
        .none => &rio.naked_wait,
        _ => |index| &rio.coro_storage.items[index.toInt()].wait_point,
    };

    enter_wait_point.awaitee = switch (reason) {
        // Coroutine has finished execution
        .idle => .idle,

        // A new operation submitted by coroutine.
        .submission => enter_wait_point.awaitee, // unchanged

        .await => |coro_index| .{ .coroutine = .{
            .index = coro_index,
        } },
    };

    wait_loop: while (!rio.waitPoint().awaitee.ready(rio)) {
        while (true) {
            switch (rio.coro_storage.queued_list_head) {
                .none => break,
                _ => |next_index| {
                    const next_coro = &rio.coro_storage.items[next_index.toInt()];
                    rio.coro_storage.queued_list_head = next_coro.list_node;
                    next_coro.list_node = .none;

                    const save_into = switch (rio.current_coro) {
                        .none => &rio.naked_wait.context,
                        _ => |index| &rio.coro_storage.items[index.toInt()].wait_point.context,
                    };

                    rio.current_coro = next_index;

                    _ = Io.fiber.contextSwitch(&.{
                        .old = save_into,
                        .new = &next_coro.wait_point.context,
                    });

                    if (rio.waitPoint().awaitee.ready(rio)) break :wait_loop;
                },
            }
        }

        _ = rio.impl.await() catch @panic("impl.await");

        while (rio.impl.completions.popFirst()) |node| {
            const completion: *Operation.Storage.Completion = @alignCast(@fieldParentPtr("node", node));
            const storage = completion.parentPtr(Operation.Storage.Tagged, "storage");

            const awaitee: *@FieldType(WaitPoint.Awaitee, "operation") = switch (storage.tag) {
                0 => @alignCast(@fieldParentPtr("primary", storage)),
                1 => @alignCast(@fieldParentPtr("cancelation", storage)),
                else => unreachable,
            };

            awaitee.outstanding -= 1;
            if (awaitee.outstanding != 0) continue; // Some operations are still pending.

            // Resume the coroutine

            const wait_point: *WaitPoint = @alignCast(@fieldParentPtr(
                "awaitee",
                @as(*WaitPoint.Awaitee, @fieldParentPtr("operation", awaitee)),
            ));

            const maybe_coro: ?*Coroutine = if (wait_point == &rio.naked_wait)
                null
            else
                @fieldParentPtr("wait_point", wait_point);

            const maybe_coro_index: Coroutine.OptionalIndex = if (maybe_coro) |coro|
                @enumFromInt(rio.coro_storage.indexOf(coro))
            else
                .none;

            if (maybe_coro_index == rio.current_coro) {
                break :wait_loop;
            }

            const save_into = switch (rio.current_coro) {
                .none => &rio.naked_wait.context,
                _ => |index| &rio.coro_storage.items[index.toInt()].wait_point.context,
            };

            rio.current_coro = maybe_coro_index;

            _ = Io.fiber.contextSwitch(&.{
                .old = save_into,
                .new = &wait_point.context,
            });
        }
    }
}

fn addVector(
    comptime mut: Impl.Mutability,
    v: []Impl.Vector(mut),
    i: *usize,
    bytes: Impl.Vector(mut).Slice,
) void {
    if (bytes.len == 0) return;
    if (v.len - i.* == 0) return;
    v[i.*] = .init(bytes);
    i.* += 1;
}

pub const Operation = union(enum) {
    net_accept: NetAccept,
    net_read: NetRead,
    net_write: NetWrite,
    sleep: Sleep,
    cancel: Cancel,
    net_receive: NetReceive,
    net_send: NetSend,

    pub const NetAccept = struct {
        listener_handle: Io.net.Socket.Handle,

        pub const Error = Io.net.Server.AcceptError;

        pub const Result = Error!Io.net.Socket;
    };

    pub const NetRead = struct {
        stream_handle: Io.net.Socket.Handle,

        // In case we need vectored I/O, this can be changed.
        buffer: []u8,

        pub const Error = Io.net.Stream.Reader.Error;

        // '0' indicates end of stream.
        pub const Result = Error!usize;
    };

    pub const NetWrite = struct {
        stream_handle: Io.net.Socket.Handle,
        data: []const Impl.Vector(.@"const"),

        pub const Error = Io.net.Stream.Writer.Error;

        pub const Result = Error!usize;
    };

    pub const Sleep = struct {
        milliseconds: u64,

        pub const Result = Io.Cancelable!void;
    };

    pub const Cancel = struct {
        operation: *Operation.Storage,

        pub const Result = void;
    };

    pub const NetReceive = struct {
        socket_handle: Io.net.Socket.Handle,
        from: *Io.net.IpAddress,
        buffer: []u8,

        pub const Error = Io.net.Socket.ReceiveError;

        pub const Result = Error!usize;
    };

    pub const NetSend = struct {
        socket_handle: Io.net.Socket.Handle,
        to: *const Io.net.IpAddress,
        buffer: []const u8,

        pub const Error = Io.net.Socket.SendError;

        pub const Result = Error!usize;
    };

    pub const Tag = @typeInfo(Operation).@"union".tag_type.?;

    pub const Result = Result: {
        const operation_fields = @typeInfo(Operation).@"union".fields;
        var field_names: [operation_fields.len][]const u8 = undefined;
        var field_types: [operation_fields.len]type = undefined;
        for (operation_fields, &field_names, &field_types) |field, *field_name, *field_type| {
            field_name.* = field.name;
            field_type.* = if (field.type == noreturn) noreturn else field.type.Result;
        }
        break :Result @Union(.auto, Tag, &field_names, &field_types, &@splat(.{}));
    };

    /// This structure must be pinned.
    pub const Storage = union {
        pub const Tagged = struct {
            tag: u32,
            storage: Storage,
        };

        submission: Submission,
        pending: Pending,
        completion: Completion,

        pub fn init(operation: Operation) Storage {
            return .{ .submission = .{
                .node = .{},
                .operation = operation,
            } };
        }

        pub const Submission = struct {
            node: std.DoublyLinkedList.Node,
            operation: Operation,
        };

        pub const Pending = struct {
            userdata: [16]usize,
        };

        pub const Completion = struct {
            node: std.DoublyLinkedList.Node,
            result: Operation.Result,

            pub fn parentPtr(c: *Completion, comptime Parent: type, comptime field_name: []const u8) *Parent {
                const storage: *Storage = @alignCast(@fieldParentPtr("completion", c));
                return @alignCast(@fieldParentPtr(field_name, storage));
            }
        };
    };
};

const native_os = builtin.os.tag;

const Io = std.Io;
const Allocator = std.mem.Allocator;
const DefaultCsprng = std.Random.DefaultCsprng;

const net = std.Io.net;
const debug = std.debug;
const linux = std.os.linux;
const windows = std.os.windows;

const std = @import("std");
const builtin = @import("builtin");
const RemiellIo = @This();
