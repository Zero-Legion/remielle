pub fn switchGameMode(
    properties: logic.Properties.Immutable(.{
        logic.Properties.BasicInfo,
    }),
    changes: logic.Changes.Subset(.{
        logic.Changes.GameMode,
    }),
    notify: Notify(pb.EnterSceneScNotify),
) !void {
    const game_mode = changes.game_mode.?;

    switch (game_mode) {
        .hall => |hall| notify.one(.{ .scene = .{
            .scene_type = 1,
            .hall_scene_data = .{
                .section_id = @intFromEnum(hall.section_id),
                .control_avatar_id = properties.basic_info.control_avatar.toInt(),
                .control_guise_avatar_id = properties.basic_info.control_guise_avatar.toInt(),
            },
        } }),
    }
}

const templates = Assets.templates;

const Notify = notifiers.Notify;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
