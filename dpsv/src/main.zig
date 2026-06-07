const log = std.log.scoped(.@"hollowell-dpsv");

pub const Options = struct {
    slots: u32 = @import("config").slots,
    listen_address: []const u8 = @import("config").listen_address,
};

pub const std_options: std.Options = .{
    .logFn = nrmio.log.logFn,
};

var cancelation: nrmio.Cancelation = .init;

var main_thread_id: Thread.Id = undefined;
var main_thread: posix.thread_t = undefined;

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

    var options_err: nrmcli.opt.ErrorDescription = undefined;
    const options = nrmcli.opt.parse(Options, args[1..], &options_err) orelse fatal(
        "{f}\nusage: {s} {f}",
        .{ options_err, args[0], nrmcli.opt.Usage(Options) },
    );

    const listen_address = posix.Sockaddr.parseIp4(options.listen_address) catch |err| {
        log.err("bad listen address specified: {t}", .{err});
        return 1;
    };

    const data = Data.build(arena.allocator()) catch |err| switch (err) {
        error.OutOfMemory => fatal("failed to build static responses", .{}),
    };

    main_thread_id = Thread.getCurrentId();
    main_thread = posix.thread_self();

    posix.sigaction(.INT, &.{
        .handler = .{ .handler = sigintHandler },
        .mask = std.mem.zeroes(@FieldType(posix.Sigaction, "mask")),
        .flags = 0,
    }, null);

    app.listen(&cancelation, arena.allocator(), options.slots, &data, &listen_address);
    return 0;
}

fn sigintHandler(_: posix.SIG) callconv(.c) void {
    cancelation.cancel();

    // Will only happen on windows
    if (Thread.getCurrentId() != main_thread_id)
        posix.thread_kill(main_thread, .IO);
}

inline fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    exit(1);
}

const is_debug = builtin.mode == .Debug;

const Init = std.process.Init;

const Thread = std.Thread;
const posix = nrmio.posix;
const heap = std.heap;
const net = std.Io.net;
const exit = std.process.exit;

const app = @import("app.zig");
const Data = @import("Data.zig");

const std = @import("std");
const nrmio = @import("nrmio");
const nrmcli = @import("nrmcli");
const builtin = @import("builtin");
