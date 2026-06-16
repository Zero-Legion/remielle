const namespaces: []const type = &.{
    @import("notifiers/player_sync.zig"),
    @import("notifiers/scene.zig"),
};

pub const NotifierError = Allocator.Error;
pub const Error = NotifierError || messaging.SendError;

pub fn notifyLogicChanges(
    arena: Allocator,
    frame: *const Server.Frame,
    changes: *const logic.Changes,
) Error!void {
    inline for (namespaces) |ns| inline for (@typeInfo(ns).@"struct".decls) |decl| {
        const Fn = @TypeOf(@field(ns, decl.name));
        const fn_info = @typeInfo(Fn).@"fn";

        if (fn_info.params.len != 2)
            @compileError("invalid parameters declared on notifier '" ++ decl.name ++ "'");

        const In = fn_info.params[0].type.?;
        const Out = @typeInfo(fn_info.params[1].type.?).pointer.child;

        if (changes.extract(In.Changes)) |in_changes| call: {
            const inputs: In = .{ .frame = frame, .changes = in_changes };
            var output: Out = .init(arena);

            @field(ns, decl.name)(inputs, &output) catch |err| switch (@as(NotifierError, err)) {
                else => |e| return e,
            };

            const notifies = switch (output.to_send) {
                .none => break :call,
                .one => |*one| one[0..1],
                .many => |many| many,
            };

            for (notifies) |notify| try messaging.send(
                frame.multi_conversation,
                frame.cvars,
                frame.target_index,
                .notify,
                notify,
            );
        }
    };
}

pub fn Inputs(
    /// A tuple of input types (fields of logic.Changes)
    comptime in_changes: anytype,
) type {
    return struct {
        const In = @This();

        pub const Changes = logic.Changes.Subset(in_changes);

        frame: *const Server.Frame,
        changes: Changes,
    };
}

pub fn Output(comptime OutNotify: type) type {
    return *struct {
        const Out = @This();

        pub const Notify = OutNotify;

        arena: Allocator,
        to_send: union(enum) {
            none: void,
            one: OutNotify,
            many: []const OutNotify,
        },

        pub fn init(arena: Allocator) Out {
            return .{ .arena = arena, .to_send = .none };
        }

        pub fn one(out: *Out, notify: OutNotify) void {
            std.debug.assert(out.to_send == .none);
            out.to_send = .{ .one = notify };
        }

        pub fn many(out: *Out, notifies: []const OutNotify) void {
            std.debug.assert(out.to_send == .none);
            out.to_send = .{ .many = notifies };
        }
    };
}

const Allocator = std.mem.Allocator;

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
