pub fn getQuestData(request: handlers.Request(.GetQuestDataCsReq)) !void {
    try request.respond(.GetQuestDataScRsp, .{
        .quest_type = request.body.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(request: handlers.Request(.GetHollowDataCsReq)) !void {
    try request.respond(.GetHollowDataScRsp, .{ .hollow_data = .init });
}

pub fn getArchiveData(request: handlers.Request(.GetArchiveDataCsReq)) !void {
    try request.respond(.GetArchiveDataScRsp, .{ .archive_data = .init });
}

const handlers = @import("../handlers.zig");
