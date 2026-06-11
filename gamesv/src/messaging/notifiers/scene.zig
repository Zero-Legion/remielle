pub fn switchGameMode(
    input: notifiers.Input(logic.Changes.GameMode),
    output: notifiers.Output(pb.EnterSceneScNotify),
) !void {
    std.debug.assert(input.changes.len == 1);

    switch (input.changes[0]) {
        .hall => |hall| output.one(.{ .scene = .{
            .scene_type = 1,
            .hall_scene_data = .{
                .section_id = @intFromEnum(hall.section_id),
                .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
                .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
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
