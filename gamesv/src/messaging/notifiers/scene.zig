pub fn switchGameMode(
    input: notifiers.Input(logic.Changes.GameMode),
    output: notifiers.Output(pb.EnterSceneScNotify),
) !void {
    std.debug.assert(input.changes.len == 1);

    const basic_info = &input.frame.cvars.properties.basic_info[input.frame.target_index];

    switch (input.changes[0]) {
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

const logic = @import("../../logic.zig");
const Assets = @import("../../Assets.zig");
const notifiers = @import("../notifiers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
