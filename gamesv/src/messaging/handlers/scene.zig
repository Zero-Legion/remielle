pub fn enterWorld(request: handlers.Request(.EnterWorldCsReq)) !void {
    try request.notify(.EnterSceneScNotify, .{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = .{
            .section_id = 1,
            .control_avatar_id = 2011,
            .control_guise_avatar_id = 1561,
        },
    } });

    try request.respond(.EnterWorldScRsp, .init);
}

pub fn enterSectionComplete(request: handlers.Request(.EnterSectionCompleteCsReq)) !void {
    try request.respond(.EnterSectionCompleteScRsp, .init);
}

const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
