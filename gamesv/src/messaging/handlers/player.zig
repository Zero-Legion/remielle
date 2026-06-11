pub fn playerLogin(
    input: handlers.Input(pb.PlayerLoginCsReq),
    output: handlers.Output(pb.PlayerLoginScRsp),
) !void {
    _ = input;
    output.respond(.init);
}

pub fn getSelfBasicInfo(
    input: handlers.Input(pb.GetSelfBasicInfoCsReq),
    output: handlers.Output(pb.GetSelfBasicInfoScRsp),
) !void {
    const info = &input.frame.cvars.properties.basic_info[input.frame.target_index];

    output.respond(.{
        .self_basic_info = .{
            .level = info.level.toInt(),
            .nick_name = "xeondev", // TODO
            .name_change_times = 1, // TODO
            .avatar_id = info.avatar.toInt(),
            .control_avatar_id = info.control_avatar.toInt(),
            .control_guise_avatar_id = info.control_guise_avatar.toInt(),
        },
    });
}

const pb = @import("rmpb").main;
const templates = Assets.templates;

const Assets = @import("../../Assets.zig");
const handlers = @import("../handlers.zig");
