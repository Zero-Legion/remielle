pub fn enterWorld(
    message: Message(pb.EnterWorldCsReq),
    changes: Changes.Builder(.{
        Changes.GameMode,
    }),
    response: Response(pb.EnterWorldScRsp),
) !void {
    _ = message;

    const mode_switch: Changes.GameMode = .{ .hall = .{
        .section_id = .MainCity_Street,
    } };

    changes.insert(mode_switch);
    response.set(.init);
}

pub fn enterSectionComplete(
    message: Message(pb.EnterSectionCompleteCsReq),
    response: Response(pb.EnterSectionCompleteScRsp),
) !void {
    _ = message;
    response.set(.init);
}

const Message = handlers.Message;
const Response = handlers.Response;

const Changes = logic.Changes;
const Properties = logic.Properties;

const logic = @import("../../logic.zig");
const handlers = @import("../handlers.zig");

const pb = @import("rmpb").main;
const std = @import("std");
