pub fn enterWorld(txn: handlers.Transaction(.EnterWorldCsReq)) !void {
    try txn.notify(.EnterSceneScNotify, .{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = .{
            .section_id = 1,
            .control_avatar_id = 2011,
            .control_guise_avatar_id = 1571,
        },
    } });

    try txn.respond(.init);
}

pub fn enterSectionComplete(txn: handlers.Transaction(.EnterSectionCompleteCsReq)) !void {
    try txn.respond(.init);
}

const handlers = @import("../handlers.zig");

const pb = @import("nrmpb").main;
const std = @import("std");
