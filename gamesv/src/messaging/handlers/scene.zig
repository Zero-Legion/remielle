pub fn enterWorld(
    input: handlers.Input(pb.EnterWorldCsReq),
    output: handlers.Output(pb.EnterWorldScRsp),
) !void {
    _ = input;

    output.changes.switchGameMode(.{ .hall = .{
        .section_id = .MainCity_Street,
    } });

    output.respond(.init);
}

pub fn enterSectionComplete(
    input: handlers.Input(pb.EnterSectionCompleteCsReq),
    output: handlers.Output(pb.EnterSectionCompleteScRsp),
) !void {
    _ = input;
    output.respond(.init);
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
