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
        const TxnPtr = fn_info.params[0].type.?;
        const Txn = @typeInfo(TxnPtr).pointer.child;

        values = values ++ .{Txn.cmd_id orelse continue};
        names = names ++ .{Txn.Body.pb_desc_name};
    };

    break :CmdId @Enum(u16, .exhaustive, names, @ptrCast(values));
};

pub const ProcessError = error{
    DecodeFail,
} || Allocator.Error || messaging.SendError;

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

        try messaging.sendDummy(multi_conversation, cvars, client, .ack(head.packet_id));
        return;
    };

    switch (cmd_id) {
        inline else => |id| lookup: inline for (namespaces) |ns| {
            inline for (@typeInfo(ns).@"struct".decls) |decl| {
                const fn_info = @typeInfo(@TypeOf(@field(ns, decl.name))).@"fn";
                const TxnPtr = fn_info.params[0].type.?;
                const Txn = @typeInfo(TxnPtr).pointer.child;

                if (@intFromEnum(id) != Txn.cmd_id) continue;

                const body = rmpb.decode(
                    .main,
                    Txn.Body,
                    arena,
                    &xored_reader.interface,
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return error.DecodeFail,
                };

                var txn: Txn = .init(arena, &body, time, cvars, client);

                @field(ns, decl.name)(&txn) catch |err| switch (@as(ProcessError, err)) {
                    else => |e| return e,
                };

                inline for (@typeInfo(@FieldType(Txn, "notifies")).@"struct".fields) |struct_field| {
                    if (@field(txn.notifies, struct_field.name)) |notify| {
                        try messaging.send(multi_conversation, cvars, client, .notify, notify);

                        log.debug(
                            Txn.log_prefix ++ "sent notify of type " ++ @TypeOf(notify).pb_desc_name ++ " to {f}",
                            .{cvars.addrs[client]},
                        );
                    }
                }

                if (Txn.Response != noreturn) {
                    if (txn.response) |response| {
                        if (rmpb.cmdId(Txn.Response) != null) {
                            try messaging.send(multi_conversation, cvars, client, .ack(head.packet_id), response);
                        } else {
                            try messaging.sendDummy(multi_conversation, cvars, client, .ack(head.packet_id));

                            log.debug(
                                Txn.log_prefix ++ "response is not described; sent dummy to {f}",
                                .{cvars.addrs[client]},
                            );
                        }
                    }
                }

                log.debug(
                    "processed message of type " ++ @typeName(Txn.Body) ++ " from {f}",
                    .{cvars.addrs[client]},
                );

                break :lookup;
            }
        } else comptime unreachable,
    }
}

fn NotifiesStruct(comptime definition_struct: anytype) type {
    const Struct = @TypeOf(definition_struct);
    const struct_fields = @typeInfo(Struct).@"struct".fields;

    var field_names: [struct_fields.len][]const u8 = undefined;
    var field_types: [struct_fields.len]type = undefined;

    inline for (struct_fields, &field_names, &field_types) |struct_field, *field_name, *field_type| {
        field_name.* = struct_field.name;
        field_type.* = ?@field(definition_struct, struct_field.name);
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

pub fn Transaction(
    comptime message_name: @EnumLiteral(),
    comptime notifies: anytype,
) type {
    return struct {
        const Txn = @This();

        pub const log_prefix = "[" ++ @tagName(message_name) ++ "] ";

        pub const Body = @field(rmpb.main, @tagName(message_name));

        pub const Response = Response: {
            const request_suffix = "CsReq";
            const response_suffix = "ScRsp";

            const name = @tagName(message_name);

            if (std.mem.endsWith(u8, name, request_suffix)) {
                const response_name = name[0 .. name.len - request_suffix.len] ++ response_suffix;
                if (@hasDecl(rmpb.main, response_name))
                    break :Response @field(rmpb.main, response_name);
            }

            break :Response noreturn;
        };

        pub const cmd_id = rmpb.cmdId(Body);

        /// The message that's received from client.
        body: *const Body,
        /// Message arrival timestamp, realtime.
        time: posix.timespec,
        /// Pending notifies, as defined by `notifies`.
        notifies: NotifiesStruct(notifies),
        /// Pending response, as inferred from `message_name`.
        response: ?Response,
        /// Global client variables.
        cvars: *ClientVariables,
        /// Originator client index.
        sender_index: u32,
        /// Per-message arena allocator.
        arena: Allocator,

        pub fn init(
            arena: Allocator,
            body: *const Body,
            time: posix.timespec,
            cvars: *ClientVariables,
            sender_index: u32,
        ) Txn {
            return .{
                .body = body,
                .time = time,
                .cvars = cvars,
                .arena = arena,
                .sender_index = sender_index,
                .response = null,
                .notifies = notifies: {
                    var n: @FieldType(Txn, "notifies") = undefined;
                    inline for (@typeInfo(@TypeOf(n)).@"struct".fields) |struct_field|
                        @field(n, struct_field.name) = null;

                    break :notifies n;
                },
            };
        }

        pub inline fn respond(txn: *Txn, rsp: Response) void {
            std.debug.assert(txn.response == null);
            txn.response = rsp;
        }

        pub inline fn notify(
            txn: *Txn,
            /// Field name from `notifies`.
            comptime name: @EnumLiteral(),
            message: @field(notifies, @tagName(name)),
        ) void {
            const field_ptr = &@field(txn.notifies, @tagName(name));
            std.debug.assert(field_ptr.* == null);
            field_ptr.* = message;
        }
    };
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ClientVariables = Server.ClientVariables;

const posix = rmio.posix;

const Server = @import("../Server.zig");
const kcp = @import("../kcp.zig");
const messaging = @import("../messaging.zig");

const rmio = @import("rmio");
const rmpb = @import("rmpb");
const std = @import("std");
