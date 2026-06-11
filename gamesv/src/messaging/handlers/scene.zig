pub fn enterWorld(txn: *handlers.Transaction(
    .EnterWorldCsReq,
    .{ .enter_scene = pb.EnterSceneScNotify },
)) !void {
    txn.notify(.enter_scene, .{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = .{
            .section_id = @intFromEnum(templates.section_config.Id.MainCity_Street),
            .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
            .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
        },
    } });

    txn.respond(.init);
}

pub fn enterSectionComplete(txn: *handlers.Transaction(.EnterSectionCompleteCsReq, .{})) !void {
    txn.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
