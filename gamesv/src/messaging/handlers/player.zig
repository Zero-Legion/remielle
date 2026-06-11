pub fn playerLogin(txn: *handlers.Transaction(.PlayerLoginCsReq, .{})) !void {
    txn.respond(.init);
}

pub fn getSelfBasicInfo(txn: *handlers.Transaction(.GetSelfBasicInfoCsReq, .{})) !void {
    txn.respond(.{ .self_basic_info = .{
        .level = 60,
        .nick_name = "xeondev",
        .name_change_times = 1,
        .avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
        .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
        .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
    } });
}

const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
