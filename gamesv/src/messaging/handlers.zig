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
        const InPtr = fn_info.params[0].type.?;
        const In = @typeInfo(InPtr).pointer.child;

        values = values ++ .{rmpb.cmdId(In.Message) orelse continue};
        names = names ++ .{In.Message.pb_desc_name};
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

                const InPtr = fn_info.params[0].type.?;
                const In = @typeInfo(InPtr).pointer.child;

                const OutPtr = fn_info.params[1].type.?;
                const Out = @typeInfo(OutPtr).pointer.child;

                if (@intFromEnum(id) != rmpb.cmdId(In.Message)) continue;

                const message = rmpb.decode(
                    .main,
                    In.Message,
                    arena,
                    &xored_reader.interface,
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return error.DecodeFail,
                };

                const input: In = .{
                    .message = &message,
                    .time = time,
                    .cvars = cvars,
                    .sender_index = client,
                };

                var output: Out = .init(arena);

                @field(ns, decl.name)(&input, &output) catch |err| switch (@as(ProcessError, err)) {
                    else => |e| return e,
                };

                inline for (@typeInfo(@FieldType(Out, "notifies")).@"struct".fields) |struct_field| {
                    if (@field(output.notifies, struct_field.name)) |notify| {
                        try messaging.send(multi_conversation, cvars, client, .notify, notify);

                        log.debug(
                            In.log_prefix ++ "sent notify of type " ++ @TypeOf(notify).pb_desc_name ++ " to {f}",
                            .{cvars.addrs[client]},
                        );
                    }
                }

                const Response = @FieldType(Out, "response");

                if (Response != void) {
                    if (output.response) |response| {
                        if (rmpb.cmdId(@typeInfo(Response).optional.child) != null) {
                            try messaging.send(multi_conversation, cvars, client, .ack(head.packet_id), response);
                        } else {
                            try messaging.sendDummy(multi_conversation, cvars, client, .ack(head.packet_id));

                            log.debug(
                                In.log_prefix ++ "response is not described; sent dummy to {f}",
                                .{cvars.addrs[client]},
                            );
                        }
                    }
                }

                log.debug(
                    "processed message of type " ++ In.Message.pb_desc_name ++ " from {f}",
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

pub fn Input(InMessage: type) type {
    return *const struct {
        const In = @This();

        pub const Message = InMessage;
        pub const log_prefix = "[" ++ InMessage.pb_desc_name ++ "] ";

        /// The incoming message.
        message: *const Message,
        /// Message arrival timestamp, realtime.
        time: posix.timespec,
        /// Global client variables.
        cvars: *ClientVariables,
        /// Originator client index.
        sender_index: u32,
    };
}

pub fn Output(
    comptime Response: ?type,
    // TODO: Get rid of notifies inside of each handler.
    comptime notifies: anytype,
) type {
    return *struct {
        const Out = @This();

        /// Temporary allocator for populating the `Output` itself.
        arena: Allocator,
        /// The outgoing response.
        response: if (Response) |R| ?R else void,
        /// The outgoing notifies. TODO: remove this.
        notifies: NotifiesStruct(notifies),

        pub fn init(arena: Allocator) Out {
            return .{
                .arena = arena,
                .response = if (Response) |_| null else {},
                .notifies = notifies: {
                    var n: @FieldType(Out, "notifies") = undefined;
                    inline for (@typeInfo(@TypeOf(n)).@"struct".fields) |struct_field|
                        @field(n, struct_field.name) = null;

                    break :notifies n;
                },
            };
        }

        pub fn respond(out: *Out, response: Response.?) void {
            std.debug.assert(out.response == null);
            out.response = response;
        }

        pub fn notify(
            out: *Out,
            /// Field name from `notifies`.
            comptime name: @EnumLiteral(),
            message: @field(notifies, @tagName(name)),
        ) void {
            const field_ptr = &@field(out.notifies, @tagName(name));
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
