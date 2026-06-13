pub const Error = error{};

const namespaces: []const type = &.{
    @import("mutators/player.zig"),
    @import("mutators/avatar.zig"),
};

pub fn dispatchLogicChanges(frame: *const Server.Frame, changes: *const logic.Changes) Error!void {
    inline for (namespaces) |ns| inline for (@typeInfo(ns).@"struct".decls) |decl| {
        const Fn = @TypeOf(@field(ns, decl.name));
        const Args = std.meta.ArgsTuple(Fn);

        var args: Args = undefined;
        var fulfilled_inputs: u32 = 0;

        inline for (@typeInfo(Args).@"struct".fields, &args) |arg_info, *arg| {
            const Arg = arg_info.type;
            const arg_type_info = @typeInfo(Arg);
            const arg_kind = comptime std.meta.activeTag(arg_type_info);

            if (arg_kind == .@"struct" and @hasDecl(Arg, "Change")) {
                arg.* = .init(frame, changes);
                fulfilled_inputs += @intFromBool(arg.anythingChanged());
            } else @compileError("Invalid argument type: " ++ @typeName(Arg));
        }

        if (fulfilled_inputs != 0) {
            @call(.auto, @field(ns, decl.name), args) catch |err| switch (@as(Error, err)) {
                else => |e| return e,
            };
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

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");

const std = @import("std");
