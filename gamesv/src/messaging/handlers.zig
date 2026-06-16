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
} || Allocator.Error || messaging.SendError || messaging.notifiers.Error;

pub fn process(
    arena: Allocator,
    frame: *const Server.Frame,
    reader: *Io.Reader,
) ProcessError!void {
    const msg_header_bytes = reader.takeArray(messaging.Header.size) catch
        return error.DecodeFail;

    const msg_header = messaging.Header.decode(msg_header_bytes) catch
        return error.DecodeFail;

    const head_bytes = reader.take(msg_header.head_len) catch
        return error.DecodeFail;

    const head = messaging.decodePacketHead(head_bytes) orelse
        return error.DecodeFail;

    var xored_reader = frame.cvars.xorpads[frame.target_index].wrapReader(reader, msg_header.body_len);

    const cmd_id = std.enums.fromInt(CmdId, msg_header.cmd_id) orelse {
        log.warn(
            "unhandled message with cmd_id {d} from {f}",
            .{ msg_header.cmd_id, frame.cvars.addrs[frame.target_index] },
        );

        if (head.packet_id == 0) return;

        try messaging.sendDummy(
            frame.multi_conversation,
            frame.cvars,
            frame.target_index,
            .ack(head.packet_id),
        );
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

                const in_message = rmpb.decode(
                    .main,
                    In.Message,
                    arena,
                    &xored_reader.interface,
                ) catch |err| switch (err) {
                    error.OutOfMemory => |e| return e,
                    else => return error.DecodeFail,
                };

                const input: In = .{
                    .frame = frame,
                    .message = &in_message,
                };

                var output: Out = .init(arena);

                @field(ns, decl.name)(&input, &output) catch |err| switch (@as(ProcessError, err)) {
                    else => |e| return e,
                };

                if (!output.failed) {
                    try logic.mutators.dispatchLogicChanges(frame, &output.changes);
                    try messaging.notifiers.notifyLogicChanges(arena, frame, &output.changes);
                }

                const OutMessage = @FieldType(Out, "message");

                if (OutMessage != void) {
                    if (output.message) |out_message| {
                        if (rmpb.cmdId(@typeInfo(OutMessage).optional.child) != null) {
                            try messaging.send(frame.multi_conversation, frame.cvars, frame.target_index, .ack(head.packet_id), out_message);
                        } else {
                            try messaging.sendDummy(frame.multi_conversation, frame.cvars, frame.target_index, .ack(head.packet_id));

                            log.debug(
                                In.log_prefix ++ "response is not described; sent dummy to {f}",
                                .{frame.cvars.addrs[frame.target_index]},
                            );
                        }
                    }
                }

                log.debug(
                    "processed message of type " ++ In.Message.pb_desc_name ++ " from {f}",
                    .{frame.cvars.addrs[frame.target_index]},
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

        frame: *const Server.Frame,
        message: *const Message,
    };
}

pub fn Output(OutMessage: ?type) type {
    return *struct {
        const Out = @This();

        pub const Message = OutMessage;

        /// Temporary allocator for populating the `Output` itself.
        arena: Allocator,
        /// The outgoing message.
        message: if (OutMessage) |Msg| ?Msg else void,
        /// Logic state modifications.
        changes: logic.Changes,
        /// If this is true, the rest of the pipeline won't be executed.
        failed: bool,

        pub fn init(arena: Allocator) Out {
            return .{
                .arena = arena,
                .message = if (OutMessage) |_| null else {},
                .changes = .init,
                .failed = false,
            };
        }

        pub fn respond(out: *Out, response: OutMessage.?) void {
            std.debug.assert(out.message == null);
            out.message = response;
        }

        pub fn bail(out: *Out, response: OutMessage.?) void {
            std.debug.assert(out.message == null);
            out.message = response;
            out.failed = true;
        }
    };
}

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ClientVariables = Server.ClientVariables;

const Server = @import("../Server.zig");

const kcp = @import("../kcp.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const rmio = @import("rmio");
const rmpb = @import("rmpb");
const std = @import("std");
