pub fn playerLogin(txn: handlers.Transaction(.PlayerLoginCsReq)) !void {
    try txn.respond(.init);
}

pub fn getSelfBasicInfo(txn: handlers.Transaction(.GetSelfBasicInfoCsReq)) !void {
    try txn.respond(.{ .self_basic_info = .{
        .level = 60,
        .nick_name = "xeondev",
        .name_change_times = 1,
        .avatar_id = 2011,
        .control_avatar_id = 2011,
        .control_guise_avatar_id = 1571,
    } });
}

const handlers = @import("../handlers.zig");
