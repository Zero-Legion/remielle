pub fn getQuestData(
    input: handlers.Input(pb.GetQuestDataCsReq),
    output: handlers.Output(pb.GetQuestDataScRsp),
) !void {
    output.respond(.{
        .quest_type = input.message.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(
    input: handlers.Input(pb.GetHollowDataCsReq),
    output: handlers.Output(pb.GetHollowDataScRsp),
) !void {
    _ = input;
    output.respond(.{ .hollow_data = .init });
}

pub fn getArchiveData(
    input: handlers.Input(pb.GetArchiveDataCsReq),
    output: handlers.Output(pb.GetArchiveDataScRsp),
) !void {
    _ = input;
    output.respond(.{ .archive_data = .init });
}

const handlers = @import("../handlers.zig");
const pb = @import("rmpb").main;
