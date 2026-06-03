const log = std.log.scoped(.@"remielle-gamesv::messaging");

const namespaces: []const type = &.{
    @import("handlers/player.zig"),
    @import("handlers/avatar.zig"),
    @import("handlers/item.zig"),
    @import("handlers/quest.zig"),
    @import("handlers/misc.zig"),
    @import("handlers/scene.zig"),
};

const CmdId = CmdId: {
    var names: []const []const u8 = &.{};
    var values: []const u16 = &.{};

    for (namespaces) |ns| for (@typeInfo(ns).@"struct".decls) |decl| {
        const fn_info = @typeInfo(@TypeOf(@field(ns, decl.name))).@"fn";
        const R = fn_info.params[0].type.?;

        values = values ++ .{R.cmd_id orelse continue};
        names = names ++ .{R.Body.pb_desc_name};
    };

    break :CmdId @Enum(u16, .exhaustive, names, @ptrCast(values));
};

pub const ProcessError = error{
    DecodeFail,
} || Allocator.Error || SendMessageError;

pub fn process(
    arena: Allocator,
    server: *kcp.Server,
    cvars: *ClientVariables,
    time: posix.timespec,
    reader: *Io.Reader,
    client: u32,
) ProcessError!void {
    const msg_header_bytes = reader.takeArray(messaging.Header.size) catch
        return error.DecodeFail;

    const msg_header = messaging.Header.decode(msg_header_bytes) catch
        return error.DecodeFail;

    const head_bytes = reader.take(msg_header.head_len) catch
        return error.DecodeFail;

    const head = messaging.decodePacketHead(head_bytes) orelse
        return error.DecodeFail;

    log.debug("received message with cmd_id {d} (packet_id: {d})", .{ msg_header.cmd_id, head.packet_id });

    var xored_reader = cvars.xorpads[client].wrapReader(reader, msg_header.body_len);

    const cmd_id = std.enums.fromInt(CmdId, msg_header.cmd_id) orelse {
        if (head.packet_id == 0) return;

        try sendDummy(server, cvars, client, head.packet_id);
        return;
    };

    switch (cmd_id) {
        inline else => |id| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decls) |decl| {
                const fn_info = @typeInfo(@TypeOf(@field(ns, decl.name))).@"fn";
                const R = fn_info.params[0].type.?;
                if (@intFromEnum(id) != R.cmd_id) continue;

                const body = rmpb.decode(
                    .main,
                    R.Body,
                    arena,
                    &xored_reader.interface,
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return error.DecodeFail,
                };

                const request: R = .{
                    .body = &body,
                    .server = server,
                    .cvars = cvars,
                    .time = time,
                    .client = client,
                    .packet_id = head.packet_id,
                };

                @field(ns, decl.name)(request) catch |err| switch (@as(ProcessError, err)) {
                    else => |e| return e,
                };

                break :lookup;
            }
        } else comptime unreachable,
    }
}

pub const SendMessageError = error{MessageOversize};

pub fn Request(comptime message_name: @EnumLiteral()) type {
    return struct {
        const R = @This();

        pub const Body = @field(rmpb.main, @tagName(message_name));
        pub const cmd_id = rmpb.cmdId(Body);

        body: *const Body,
        server: *kcp.Server,
        cvars: *ClientVariables,
        time: posix.timespec,
        client: u32,
        packet_id: u32,

        pub fn respond(
            r: *const R,
            comptime response_name: @EnumLiteral(),
            rsp: @field(rmpb.main, @tagName(response_name)),
        ) SendMessageError!void {
            const id = comptime rmpb.cmdId(@TypeOf(rsp)) orelse {
                try sendDummy(r.server, r.cvars, r.client, r.packet_id);
                return;
            };

            defer r.cvars.packet_id_counters[r.client] += 1;
            try sendMessage(r.server, &r.cvars.xorpads[r.client], r.client, .{
                .packet_id = r.cvars.packet_id_counters[r.client],
                .ack_packet_id = r.packet_id,
            }, id, rsp);
        }

        pub fn notify(
            r: *const R,
            comptime ntf_name: @EnumLiteral(),
            ntf: @field(rmpb.main, @tagName(ntf_name)),
        ) SendMessageError!void {
            const id = comptime rmpb.cmdId(@TypeOf(ntf)) orelse return;

            defer r.cvars.packet_id_counters[r.client] += 1;
            try sendMessage(r.server, &r.cvars.xorpads[r.client], r.client, .{
                .packet_id = r.cvars.packet_id_counters[r.client],
            }, id, ntf);
        }
    };
}

fn sendMessage(
    server: *kcp.Server,
    xorpad: *const messaging.Xorpad,
    client: u32,
    head: rmpb.stable.PacketHead,
    cmd_id: u16,
    message: anytype,
) SendMessageError!void {
    const length = messaging.encodingLength(head, message);

    var writer: kcp.Server.SegWriter = .init(
        &server.conversations.rings[client].send,
        try server.allocPushSegments(client, length),
    );

    messaging.encode(
        &writer.interface,
        xorpad,
        cmd_id,
        head,
        message,
    ) catch unreachable;
}

fn sendDummy(server: *kcp.Server, cvars: *ClientVariables, client: u32, packet_id: u32) !void {
    const DummyCmd = comptime DummyCmd: {
        const ns = rmpb.Descriptors.main.namespace();
        const name = @import("config").dummy_cmd;
        if (!@hasDecl(ns, name))
            @compileError("the `dummy_cmd` is invalid");

        break :DummyCmd @field(ns, name);
    };

    const dummy: DummyCmd = .{};
    defer cvars.packet_id_counters[client] += 1;

    try sendMessage(server, &cvars.xorpads[client], client, .{
        .packet_id = cvars.packet_id_counters[client],
        .ack_packet_id = packet_id,
    }, DummyCmd.cmd_id, dummy);
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ClientVariables = app.ClientVariables;

const posix = rmio.posix;

const app = @import("../app.zig");
const kcp = @import("../kcp.zig");
const messaging = @import("../messaging.zig");

const rmio = @import("rmio");
const rmpb = @import("rmpb");
const std = @import("std");
