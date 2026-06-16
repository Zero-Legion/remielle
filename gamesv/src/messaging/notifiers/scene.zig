pub fn switchGameMode(
    inputs: Inputs(.{logic.Changes.GameMode}),
    output: Output(pb.EnterSceneScNotify),
) !void {
    const game_mode = inputs.changes.game_mode.?;
    const basic_info = &inputs.frame.cvars.properties.basic_info[inputs.frame.target_index];

    switch (game_mode) {
        .hall => |hall| output.one(.{ .scene = .{
            .scene_type = 1,
            .hall_scene_data = .{
                .section_id = @intFromEnum(hall.section_id),
                .control_avatar_id = basic_info.control_avatar.toInt(),
                .control_guise_avatar_id = basic_info.control_guise_avatar.toInt(),
            },
        } }),
    }
}

const templates = Assets.templates;

const Inputs = notifiers.Inputs;
const Output = notifiers.Output;

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
