game_mode: ?GameMode,
avatars: []const Avatar,

pub const init: Changes = .{
    .game_mode = null,
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

/// Avatar modification.
pub const Avatar = struct {
    id: Properties.Avatar.Id,
    level: Properties.Avatar.Level,
    exp: u32,
    rank: Properties.Avatar.Rank,
    talents: Properties.Avatar.Talents,
    talent_switch: Properties.Avatar.TalentSwitch,
    skill_levels: [Properties.Avatar.Skill.count]Properties.Avatar.Skill.Level,
    flags: Properties.Avatar.Flags,
    weapon_uid: Properties.Avatar.OptionalUID,
    equipment_uids: [Properties.Avatar.equipment_slots]Properties.Avatar.OptionalUID,
};

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const Properties = @import("Properties.zig");

const std = @import("std");
const Changes = @This();
