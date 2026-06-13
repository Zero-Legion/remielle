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

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const Properties = @import("Properties.zig");

const std = @import("std");
const Changes = @This();
