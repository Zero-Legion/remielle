const log = std.log.scoped(.@"remielle-dpsv");

pub const Options = struct {
    slots: u32 = @import("config").slots,
    listen_address: []const u8 = @import("config").listen_address,
};

pub fn main(init: Init.Minimal) u8 {
    var debug_allocator: heap.DebugAllocator(.{}) = .init;
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const gpa = if (is_debug)
        debug_allocator.allocator()
    else
        heap.smp_allocator;

    var arena: heap.ArenaAllocator = .init(gpa);
    defer if (is_debug) arena.deinit();

    const args = init.args.toSlice(arena.allocator()) catch |err|
        fatal("failed to collect cli arguments: {t}", .{err});

    var options_err: rmcli.opt.ErrorDescription = undefined;
    const options = rmcli.opt.parse(Options, args[1..], &options_err) orelse fatal(
        "{f}\nusage: {s} {f}",
        .{ options_err, args[0], rmcli.opt.Usage(Options) },
    );

    const listen_address = net.IpAddress.parseLiteral(options.listen_address) catch |err| {
        log.err("bad listen address specified: {t}", .{err});
        return 1;
    };

    var io_impl = if (rmio.RemiellIo.supported)
        rmio.RemiellIo.init(gpa, .{ .coroutines = options.slots, .stack_size = 1024 * 32 }) catch |err|
            fatal("failed to init I/O implementation: {t}", .{err})
    else
        std.Io.Threaded.init(gpa, .{});

    defer io_impl.deinit();
    const io = io_impl.io();

    const slots = gpa.alloc(app.Slot, options.slots) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to allocate {d} connection slots", .{options.slots}),
    };

    defer if (is_debug) gpa.free(slots);

    const data = Data.build(arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to build static responses", .{}),
    };

    return app.listen(io, &data, slots, listen_address);
}

inline fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    exit(1);
}

const is_debug = builtin.mode == .Debug;

const Init = std.process.Init;

const heap = std.heap;
const net = std.Io.net;
const exit = std.process.exit;

const app = @import("app.zig");
const Data = @import("Data.zig");

const std = @import("std");
const rmio = @import("rmio");
const rmcli = @import("rmcli");
const builtin = @import("builtin");
