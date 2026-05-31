pub fn playerLogin(request: handlers.Request(.PlayerLoginCsReq)) !void {
    try request.respond(.PlayerLoginScRsp, .{});
}

pub fn getSelfBasicInfo(request: handlers.Request(.GetSelfBasicInfoCsReq)) !void {
    try request.respond(.GetSelfBasicInfoScRsp, .{ .self_basic_info = .{
        .level = 60,
        .nick_name = "xeondev",
        .name_change_times = 1,
        .avatar_id = 2011,
        .control_avatar_id = 2011,
        .control_guise_avatar_id = 1561,
    } });
}

const handlers = @import("../handlers.zig");
