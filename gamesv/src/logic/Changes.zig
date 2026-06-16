game_mode: ?GameMode,
control_avatar: ?ControlAvatar,
control_guise_avatar: ?ControlGuiseAvatar,
avatars: []const Avatar,

pub const init: Changes = .{
    .game_mode = null,
    .control_avatar = null,
    .control_guise_avatar = null,
    .avatars = &.{},
};

pub fn switchGameMode(changes: *Changes, gm: GameMode) void {
    std.debug.assert(changes.game_mode == null); // Tried to switch game mode twice.
    changes.game_mode = gm;
}

/// Game mode switch.
pub const GameMode = union(enum) {
    hall: Hall,

    /// Load hall game mode.
    pub const Hall = struct {
        section_id: templates.section_config.Id,
    };
};

pub const ControlAvatar = Properties.HallAvatar;

pub const ControlGuiseAvatar = Properties.HallAvatar.Guise;

/// Avatar modification.
pub const Avatar = struct {
    id: Properties.Avatar.Id,
    meta: Properties.Avatar.Meta,
    weapon_uid: Properties.Avatar.OptionalUID,
    equipment_uids: [Properties.Avatar.equipment_slots]Properties.Avatar.OptionalUID,
};

pub const subset_marker_name = "logic_changes_subset_marker";

pub fn Subset(comptime types: anytype) type {
    var field_types: [types.len + 1]type = undefined;
    var field_names: [types.len + 1][]const u8 = undefined;

    // Add a ZST field as a marker
    field_types[0] = void;
    field_names[0] = subset_marker_name;

    const changes_fields = @typeInfo(Changes).@"struct".fields;

    for (types, field_types[1..], field_names[1..]) |C, *field_type, *field_name| {
        search: for (changes_fields) |changes_field| {
            if (changes_field.type == ?C or changes_field.type == []const C) {
                field_type.* = changes_field.type;
                field_name.* = changes_field.name;
                break :search;
            }
        } else @compileError("Invalid change type: " ++ @typeName(C));
    }

    return @Struct(.auto, null, &field_names, &field_types, &@splat(.{}));
}

/// Returns `null` if not a single field is active.
pub fn extract(logic_changes: *const Changes, comptime Sub: type) ?Sub {
    var subset: Sub = undefined;
    var any_fulfilled: u1 = 0;

    inline for (@typeInfo(Sub).@"struct".fields) |field| {
        if (field.type == void) continue;

        @field(subset, field.name) = @field(logic_changes, field.name);

        switch (@typeInfo(field.type)) {
            .pointer => any_fulfilled |= @intFromBool(@field(logic_changes, field.name).len != 0),
            .optional => any_fulfilled |= @intFromBool(@field(logic_changes, field.name) != null),
            else => comptime unreachable,
        }
    }

    return if (any_fulfilled != 0) subset else null;
}

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const Server = @import("../Server.zig");
const Properties = @import("Properties.zig");

const std = @import("std");
const Changes = @This();
