const log = std.log.scoped(.@"hollowell-gamesv::messaging");

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
    multi_conversation: *kcp.MultiConversation,
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

    var xored_reader = cvars.xorpads[client].wrapReader(reader, msg_header.body_len);

    const cmd_id = std.enums.fromInt(CmdId, msg_header.cmd_id) orelse {
        log.warn(
            "unhandled message with cmd_id {d} from {f}",
            .{ msg_header.cmd_id, cvars.addrs[client] },
        );

        if (head.packet_id == 0) return;

        try sendDummy(multi_conversation, cvars, client, head.packet_id);
        return;
    };

    switch (cmd_id) {
        inline else => |id| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decls) |decl| {
                const fn_info = @typeInfo(@TypeOf(@field(ns, decl.name))).@"fn";
                const R = fn_info.params[0].type.?;
                if (@intFromEnum(id) != R.cmd_id) continue;

                const body = nrmpb.decode(
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
                    .multi_conversation = multi_conversation,
                    .cvars = cvars,
                    .time = time,
                    .client_index = client,
                    .packet_id = head.packet_id,
                };

                @field(ns, decl.name)(request) catch |err| switch (@as(ProcessError, err)) {
                    else => |e| return e,
                };

                log.debug(
                    "processed message of type " ++ @typeName(R.Body) ++ " from {f}",
                    .{cvars.addrs[client]},
                );

                break :lookup;
            }
        } else comptime unreachable,
    }
}

pub const SendMessageError = error{MessageOversize};

pub fn Transaction(comptime message_name: @EnumLiteral()) type {
    return struct {
        const Txn = @This();

        pub const Body = @field(nrmpb.main, @tagName(message_name));

        pub const Response = Response: {
            const request_suffix = "CsReq";
            const response_suffix = "ScRsp";

            const name = @tagName(message_name);

            if (std.mem.endsWith(u8, name, request_suffix)) {
                const response_name = name[0 .. name.len - request_suffix.len] ++ response_suffix;
                if (@hasDecl(nrmpb.main, response_name))
                    break :Response @field(nrmpb.main, response_name);
            }

            break :Response noreturn;
        };

        pub const cmd_id = nrmpb.cmdId(Body);

        body: *const Body,
        multi_conversation: *kcp.MultiConversation,
        cvars: *ClientVariables,
        time: posix.timespec,
        client_index: u32,
        packet_id: u32,

        pub fn respond(
            txn: *const Txn,
            rsp: Response,
        ) SendMessageError!void {
            const id = (comptime nrmpb.cmdId(Response)) orelse {
                try sendDummy(txn.multi_conversation, txn.cvars, txn.client_index, txn.packet_id);
                log.debug(
                    "response of type " ++ @typeName(Response) ++ " is not described; sent dummy to {f}",
                    .{txn.cvars.addrs[txn.client_index]},
                );
                return;
            };

            defer txn.cvars.packet_id_counters[txn.client_index] += 1;

            try sendMessage(txn.multi_conversation, &txn.cvars.xorpads[txn.client_index], txn.client_index, .{
                .packet_id = txn.cvars.packet_id_counters[txn.client_index],
                .ack_packet_id = txn.packet_id,
            }, id, rsp);

            log.debug(
                "sent response of type " ++ @typeName(Response) ++ " to {f}",
                .{txn.cvars.addrs[txn.client_index]},
            );
        }

        pub fn notify(
            txn: *const Txn,
            comptime ntf_name: @EnumLiteral(),
            ntf: @field(nrmpb.main, @tagName(ntf_name)),
        ) SendMessageError!void {
            const id = (comptime nrmpb.cmdId(@TypeOf(ntf))) orelse {
                log.debug("notify of type " ++ @typeName(Response) ++ " is not described", .{});
                return;
            };

            defer txn.cvars.packet_id_counters[txn.client_index] += 1;
            try sendMessage(txn.multi_conversation, &txn.cvars.xorpads[txn.client_index], txn.client_index, .{
                .packet_id = txn.cvars.packet_id_counters[txn.client_index],
            }, id, ntf);

            log.debug(
                "sent notify of type " ++ @typeName(@TypeOf(ntf)) ++ " to {f}",
                .{txn.cvars.addrs[txn.client_index]},
            );
        }
    };
}

fn sendMessage(
    multi_conversation: *kcp.MultiConversation,
    xorpad: *const messaging.Xorpad,
    client: u32,
    head: nrmpb.stable.PacketHead,
    cmd_id: u16,
    message: anytype,
) SendMessageError!void {
    const length = messaging.encodingLength(head, message);

    var writer = try multi_conversation.writer(client, length);

    messaging.encode(
        &writer.interface,
        xorpad,
        cmd_id,
        head,
        message,
    ) catch unreachable;
}

fn sendDummy(multi_conversation: *kcp.MultiConversation, cvars: *ClientVariables, client: u32, packet_id: u32) !void {
    const DummyCmd = comptime DummyCmd: {
        const ns = nrmpb.Descriptors.main.namespace();
        const name = @import("config").dummy_cmd;
        if (!@hasDecl(ns, name))
            @compileError("the `dummy_cmd` is invalid");

        break :DummyCmd @field(ns, name);
    };

    const dummy: DummyCmd = .{};
    defer cvars.packet_id_counters[client] += 1;

    try sendMessage(multi_conversation, &cvars.xorpads[client], client, .{
        .packet_id = cvars.packet_id_counters[client],
        .ack_packet_id = packet_id,
    }, DummyCmd.cmd_id, dummy);
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ClientVariables = Server.ClientVariables;

const posix = nrmio.posix;

const Server = @import("../Server.zig");
const kcp = @import("../kcp.zig");
const messaging = @import("../messaging.zig");

const nrmio = @import("nrmio");
const nrmpb = @import("nrmpb");
const std = @import("std");
