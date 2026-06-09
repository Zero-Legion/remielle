pub fn enterWorld(txn: handlers.Transaction(.EnterWorldCsReq)) !void {
    try txn.notify(.EnterSceneScNotify, .{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = .{
            .section_id = 1,
            .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
            .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
        },
    } });

    try txn.respond(.init);
}

pub fn enterSectionComplete(txn: handlers.Transaction(.EnterSectionCompleteCsReq)) !void {
    try txn.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
