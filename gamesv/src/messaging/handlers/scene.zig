pub fn enterWorld(
    input: handlers.Input(pb.EnterWorldCsReq),
    output: handlers.Output(pb.EnterWorldScRsp, .{ .enter_scene = pb.EnterSceneScNotify }),
) !void {
    _ = input;

    output.notify(.enter_scene, .{ .scene = .{
        .scene_type = 1,
        .hall_scene_data = .{
            .section_id = @intFromEnum(templates.section_config.Id.MainCity_Street),
            .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
            .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
        },
    } });

    output.respond(.init);
}

pub fn enterSectionComplete(
    input: handlers.Input(pb.EnterSectionCompleteCsReq),
    output: handlers.Output(pb.EnterSectionCompleteScRsp, .{}),
) !void {
    _ = input;
    output.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
