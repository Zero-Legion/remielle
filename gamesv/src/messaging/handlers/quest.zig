pub fn getQuestData(
    message: Message(pb.GetQuestDataCsReq),
    response: Response(pb.GetQuestDataScRsp),
) !void {
    response.set(.{
        .quest_type = message.data.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(
    message: Message(pb.GetHollowDataCsReq),
    response: Response(pb.GetHollowDataScRsp),
) !void {
    _ = message;
    response.set(.{ .hollow_data = .init });
}

pub fn getArchiveData(
    message: Message(pb.GetArchiveDataCsReq),
    response: Response(pb.GetArchiveDataScRsp),
) !void {
    _ = message;
    response.set(.{ .archive_data = .init });
}

const Message = handlers.Message;
const Response = handlers.Response;

const handlers = @import("../handlers.zig");
const pb = @import("rmpb").main;
