pub const Error = error{};

const namespaces: []const type = &.{
    @import("mutators/player.zig"),
    @import("mutators/avatar.zig"),
};

pub fn dispatchLogicChanges(frame: *const Server.Frame, changes: *const logic.Changes) Error!void {
    inline for (namespaces) |ns| inline for (@typeInfo(ns).@"struct".decls) |decl| {
        const Fn = @TypeOf(@field(ns, decl.name));
        const fn_info = @typeInfo(Fn).@"fn";

        if (fn_info.params.len != 1)
            @compileError("invalid parameters declared on mutator '" ++ decl.name ++ "'");

        const In = fn_info.params[0].type.?;

        if (changes.extract(In.Changes)) |in_changes| {
            const inputs: In = .{ .frame = frame, .changes = in_changes };

            @field(ns, decl.name)(inputs) catch |err| switch (@as(Error, err)) {
                else => |e| return e,
            };
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

const Server = @import("../Server.zig");
const logic = @import("../logic.zig");

const std = @import("std");
