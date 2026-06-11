game_mode: ?GameMode,

pub const init: Changes = .{
    .game_mode = null,
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

const templates = Assets.templates;

const Assets = @import("../Assets.zig");
const std = @import("std");

const Changes = @This();
