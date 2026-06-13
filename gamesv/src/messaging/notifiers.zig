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
        const Args = std.meta.ArgsTuple(Fn);

        var outputs: OutputsOf(Fn) = undefined;
        comptime var outputs_i: u32 = 0;

        var args: Args = undefined;
        var fulfilled_inputs: u32 = 0;

        inline for (@typeInfo(Args).@"struct".fields, &args) |arg_info, *arg| {
            const Arg = arg_info.type;
            const arg_type_info = @typeInfo(Arg);
            const arg_kind = comptime std.meta.activeTag(arg_type_info);

            if (arg_kind == .@"struct" and @hasDecl(Arg, "Change")) {
                arg.* = .init(frame, changes);
                fulfilled_inputs += @intFromBool(arg.anythingChanged());
            } else if (arg_kind == .pointer and @hasDecl(arg_type_info.pointer.child, "Notify")) {
                outputs[outputs_i] = .init(arena);
                arg.* = &outputs[outputs_i];
                outputs_i += 1;
            } else @compileError("Invalid argument type: " ++ @typeName(Arg));
        }

        if (fulfilled_inputs != 0) {
            @call(.auto, @field(ns, decl.name), args) catch |err| switch (@as(NotifierError, err)) {
                else => |e| return e,
            };

            inline for (&outputs) |output| {
                send: {
                    const notifies = switch (output.to_send) {
                        .none => break :send,
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
            }
        }
    };
}

pub fn Input(comptime InChange: type) type {
    return struct {
        const In = @This();

        pub const Change = InChange;

        frame: *const Server.Frame,
        changes: if (Change == logic.Changes)
            *const logic.Changes
        else
            []const Change,

        pub fn init(frame: *const Server.Frame, logic_changes: *const logic.Changes) In {
            if (Change == logic.Changes)
                return .{ .frame = frame, .changes = logic_changes };

            const changes: []const Change = changes: inline for (
                @typeInfo(logic.Changes).@"struct".fields,
            ) |struct_field| {
                switch (struct_field.type) {
                    ?Change => break :changes if (@field(logic_changes, struct_field.name)) |*change|
                        change[0..1]
                    else
                        &.{},
                    []const Change, []Change => break :changes @field(logic_changes, struct_field.name),
                    else => continue,
                }
            } else @compileError("Invalid change type: " ++ @typeName(Change));

            return .{ .changes = changes, .frame = frame };
        }

        fn anythingChanged(in: *const In) bool {
            return if (Change == logic.Changes)
                true
            else
                in.changes.len != 0;
        }
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

fn OutputsOf(Fn: type) type {
    var types: []const type = &.{};

    inline for (@typeInfo(Fn).@"fn".params) |param| {
        switch (@typeInfo(param.type.?)) {
            .pointer => |pointer| if (@hasDecl(pointer.child, "Notify")) {
                types = types ++ [1]type{pointer.child};
            },
            else => continue,
        }
    }

    return @Tuple(types);
}

const Allocator = std.mem.Allocator;

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
