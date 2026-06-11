pub fn playerLogin(
    input: handlers.Input(pb.PlayerLoginCsReq),
    output: handlers.Output(pb.PlayerLoginScRsp, .{}),
) !void {
    _ = input;
    output.respond(.init);
}

pub fn getSelfBasicInfo(
    input: handlers.Input(pb.GetSelfBasicInfoCsReq),
    output: handlers.Output(pb.GetSelfBasicInfoScRsp, .{}),
) !void {
    _ = input;
    output.respond(.{ .self_basic_info = .{
        .level = 60,
        .nick_name = "xeondev",
        .name_change_times = 1,
        .avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
        .control_avatar_id = @intFromEnum(templates.avatar_base.Id.wise),
        .control_guise_avatar_id = @intFromEnum(templates.avatar_base.Id.velina),
    } });
}

const pb = @import("rmpb").main;
const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
