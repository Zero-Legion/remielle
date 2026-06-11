pub fn getQuestData(txn: *handlers.Transaction(.GetQuestDataCsReq, .{})) !void {
    txn.respond(.{
        .quest_type = txn.body.quest_type,
        .quest_data = .init,
    });
}

pub fn getHollowData(txn: *handlers.Transaction(.GetHollowDataCsReq, .{})) !void {
    txn.respond(.{ .hollow_data = .init });
}

pub fn getArchiveData(txn: *handlers.Transaction(.GetArchiveDataCsReq, .{})) !void {
    txn.respond(.{ .archive_data = .init });
}

const handlers = @import("../handlers.zig");
