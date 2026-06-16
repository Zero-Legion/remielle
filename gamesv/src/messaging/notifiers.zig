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

        var output: OutputOf(Fn) = .init(arena);

        var args: Args = undefined;
        var fulfilled_inputs: u32 = 0;

        inline for (@typeInfo(Args).@"struct".fields, &args) |arg_info, *arg| {
            switch (arg_info.type) {
                *OutputOf(Fn) => arg.* = &output,
                else => |Arg| switch (@typeInfo(Arg)) {
                    .@"struct" => if (@hasDecl(Arg, "Change")) {
                        arg.* = .init(frame, changes);
                        fulfilled_inputs += @intFromBool(arg.anythingChanged());
                    } else @compileError("Invalid argument type: " ++ @typeName(Arg)),
                    else => |kind| @compileError("Invalid argument kind: " ++ @tagName(kind)),
                },
            }
        }

        if (fulfilled_inputs != 0) call: {
            @call(.auto, @field(ns, decl.name), args) catch |err| switch (@as(NotifierError, err)) {
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

pub fn Input(comptime InChange: type) type {
    return struct {
        const In = @This();

        pub const Change = InChange;

        frame: *const Server.Frame,
        changes: []const Change,

        pub fn init(frame: *const Server.Frame, logic_changes: *const logic.Changes) In {
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
            return in.changes.len != 0;
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

fn OutputOf(Fn: type) type {
    var Type: ?type = null;

    inline for (@typeInfo(Fn).@"fn".params) |param| {
        switch (@typeInfo(param.type.?)) {
            .pointer => |pointer| if (@hasDecl(pointer.child, "Notify")) {
                if (Type != null) @compileError("notifiers: multiple outputs are not allowed");
                Type = pointer.child;
            },
            else => continue,
        }
    }

    return Type orelse @compileError("notifiers: not a single output defined");
}

const Allocator = std.mem.Allocator;

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");
const messaging = @import("../messaging.zig");

const std = @import("std");
